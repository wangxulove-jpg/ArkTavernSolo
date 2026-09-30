/**
 * ChatOneShotGenerator 单次非流式生成(代写 / 性格提取与总结 / 续写)(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 方法整块搬出):
 * - extractUserFromCharacter:根据角色卡提取用户身份特征
 * - summarizeUserPersona:根据用户发言总结性格与说话风格
 * - generateImpersonateCandidates + parseImpersonateCandidates:代写候选生成与解析
 * - autoContinue + parseAutoContinueTurn:续写(下一句用户发言 + 角色回应)与解析
 *
 * 依赖与宿主(ArkTS 说明):
 * - ChatService 相关成员多为 private,无法用"结构类型直接传 this"的宿主契约,
 *   故:服务依赖经构造函数注入(只读引用,与 ChatService 同批装配);
 *   可变会话状态与宿主私有能力经 ChatOneShotHost 回调读写——保持"读取即最新、
 *   写入即生效",与搬运前 this.xxx 的读写时机完全一致;类内以同名的
 *   getter/setter/方法转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatOneShotGenerator(仅日志来源标注变化)。
 */

import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import { Character, resolveCharacterDisplayName } from '../models/Character';
import { extractImpresDirection } from '../models/CardImpres';
import { ChatStatusEntry, parseChatStatusState } from '../models/ChatStatusState';
import { ChatRequest } from '../models/ChatRequest';
import { ChatResponse } from '../models/ChatResponse';
import { ProviderConfig } from '../models/ProviderConfig';
import { ImpersonateCandidate } from '../models/ImpersonateCandidate';
import { ChatState, ChatServiceCallbacks } from '../models/ChatServiceContract';
import { AppPreferences } from '../storage/AppPreferences';
import { ModelService } from './ModelService';
import { AppendUserAndAssistantResult, ChatPersistenceService } from './ChatPersistenceService';
import {
  PromptPresetRequestSnapshot,
  EffectiveGenerationSettings,
  resolveEffectiveGenerationSettings
} from './PromptPresetRuntimeResolver';
import { IMPRES_GUIDE_KEY, CONTINUE_GUIDE_KEY } from './ChatTextContract';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatOneShotGenerator';

/** 代写注入上限:代写方向(字符,超出截断) */
const IMPRES_DIRECTION_MAX_CHARS: number = 4000;
/** 代写注入上限:开场白(字符,超出截断) */
const IMPRES_OPENING_MAX_CHARS: number = 2000;
/** 代写注入上限:角色状态条数 */
const IMPRES_STATUS_MAX_ENTRIES: number = 30;

/** 续写单次请求解析结果:用户下一句发言 + 角色回应 */
interface AutoContinueTurn {
  user: string;
  assistant: string;
}

/** 生成器依赖(全部为只读引用,null 表示未装配) */
export interface ChatOneShotDeps {
  /** 模型服务(配置读取与非流式 sendChat) */
  modelService: ModelService;
  /** 会话持久化服务(续写落库) */
  persistenceService: ChatPersistenceService | null;
  /** 全局偏好(代写/续写自定义引导读取) */
  appPreferences: AppPreferences | null;
}

/**
 * 宿主回调:可变会话状态读写与宿主私有能力。
 * 读取即最新、写入即生效(与搬运前 this.xxx 的读写语义一致)。
 */
export interface ChatOneShotHost {
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 是否正在生成(代写/续写与主线生成互斥判定) */
  isBusy: () => boolean;
  /** 当前角色卡(可能为 null) */
  getCharacter: () => Character | null;
  /** 当前消息列表(按时间正序;调用方不得直接修改返回值) */
  getMessages: () => ChatMessage[];
  /** 整体替换消息列表(不可变更新产生的新数组) */
  setMessages: (messages: ChatMessage[]) => void;
  /** 当前会话(可能为 null) */
  getCurrentChat: () => Chat | null;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 最近一次回调读取 */
  getLastCallbacks: () => ChatServiceCallbacks | null;
  /** 记录最近一次回调(宿主在停止/收尾时读取) */
  setLastCallbacks: (callbacks: ChatServiceCallbacks | null) => void;
  /** 生成操作号读取(迟到回调判定用) */
  getGenerationOperationId: () => number;
  /** 生成操作号更新 */
  setGenerationOperationId: (operationId: number) => void;
  /** 当前持久化序号读取 */
  getCurrentSequenceNumber: () => number;
  /** 当前持久化序号更新 */
  setCurrentSequenceNumber: (sequenceNumber: number) => void;
  /** 当前 Assistant 消息 id 读取 */
  getCurrentAssistantId: () => string | null;
  /** 当前 Assistant 消息 id 更新 */
  setCurrentAssistantId: (assistantId: string | null) => void;
  /** 解析用户称呼(对话覆盖 > 角色设置 > 全局设置 > User) */
  resolveUserName: () => Promise<string>;
  /** 创建预设请求快照(与主线发送一致,保持缓存前缀稳定) */
  createPresetRequestSnapshot: () => Promise<PromptPresetRequestSnapshot>;
  /** 构建请求消息列表(实现已抽至 ChatRequestBuilder) */
  buildRequestMessages: (presetSystemPrompt?: string) => Promise<ChatMessage[]>;
  /** 设置聊天状态(宿主内做 disposed 判定与去重) */
  setState: (state: ChatState, callbacks: ChatServiceCallbacks | null) => void;
  /** 通知消息列表变更 */
  emitMessages: (callbacks: ChatServiceCallbacks | null) => void;
  /** 更新 Chat 活跃时间(异步,不等待) */
  persistChatActivity: () => void;
}

export class ChatOneShotGenerator {
  private readonly modelService: ModelService;
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly appPreferences: AppPreferences | null;
  private readonly host: ChatOneShotHost;

  constructor(deps: ChatOneShotDeps, host: ChatOneShotHost) {
    this.modelService = deps.modelService;
    this.persistenceService = deps.persistenceService;
    this.appPreferences = deps.appPreferences;
    this.host = host;
  }

  // ===== 宿主状态读写(同名 getter/setter 转发,保持搬运代码零改写) =====

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
  }

  private get currentChat(): Chat | null {
    return this.host.getCurrentChat();
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get lastCallbacks(): ChatServiceCallbacks | null {
    return this.host.getLastCallbacks();
  }

  private set lastCallbacks(value: ChatServiceCallbacks | null) {
    this.host.setLastCallbacks(value);
  }

  private get generationOperationId(): number {
    return this.host.getGenerationOperationId();
  }

  private set generationOperationId(value: number) {
    this.host.setGenerationOperationId(value);
  }

  private get currentSequenceNumber(): number {
    return this.host.getCurrentSequenceNumber();
  }

  private set currentSequenceNumber(value: number) {
    this.host.setCurrentSequenceNumber(value);
  }

  private get currentAssistantId(): string | null {
    return this.host.getCurrentAssistantId();
  }

  private set currentAssistantId(value: string | null) {
    this.host.setCurrentAssistantId(value);
  }

  // ===== 宿主能力(同名方法转发) =====

  private isBusy(): boolean {
    return this.host.isBusy();
  }

  private resolveUserName(): Promise<string> {
    return this.host.resolveUserName();
  }

  private createPresetRequestSnapshot(): Promise<PromptPresetRequestSnapshot> {
    return this.host.createPresetRequestSnapshot();
  }

  private buildRequestMessages(presetSystemPrompt?: string): Promise<ChatMessage[]> {
    return this.host.buildRequestMessages(presetSystemPrompt);
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    this.host.setState(state, callbacks);
  }

  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    this.host.emitMessages(callbacks);
  }

  private persistChatActivity(): void {
    this.host.persistChatActivity();
  }

  // ===== 搬运方法(原 ChatService 方法,逐字搬出) =====

  async extractUserFromCharacter(): Promise<string> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.character === null) {
      throw new Error('当前会话无角色');
    }
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }
    const char: Character = this.character;
    const charInfo: string = [
      '角色名: ' + char.name,
      char.description.length > 0 ? '描述: ' + char.description : '',
      char.personality.length > 0 ? '性格: ' + char.personality : '',
      char.scenario.length > 0 ? '场景: ' + char.scenario : '',
      char.mesExample.length > 0 ? '对话示例: ' + char.mesExample : ''
    ].filter((s: string) => s.length > 0).join('\n');

    const systemMsg: ChatMessage = {
      id: 'sys-extract-user',
      role: ChatRole.System,
      content: '你是一个角色分析专家。根据以下角色卡信息，分析并提取出与用户（{{user}}）互动相关的身份特征：\n- 用户在故事中扮演什么角色（如：朋友、恋人、同事、陌生人等）\n- 用户与角色的关系动态\n- 用户可能拥有的隐含特征（根据角色对用户的态度推断）\n\n输出格式：用2-3句话简洁描述，不要编造角色卡中没有的信息，只提取合理推断的内容。',
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const userMsg: ChatMessage = {
      id: 'usr-extract-user',
      role: ChatRole.User,
      content: charInfo,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const request: ChatRequest = {
      model: modelName,
      messages: [systemMsg, userMsg],
      temperature: 0.3,
      topP: 0.9,
      maxTokens: 512,
      stream: false
    };
    const response: ChatResponse = await this.modelService.sendChat(request);
    const summary: string = response.content.trim();
    if (summary.length === 0) {
      throw new Error('AI 返回为空');
    }
    return summary;
  }

  async summarizeUserPersona(): Promise<string> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }
    const userMessages: string[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].role === ChatRole.User) {
        userMessages.push(this.messages[i].content);
      }
    }
    if (userMessages.length === 0) {
      throw new Error('当前对话无用户消息');
    }
    let combined: string = userMessages.join('\n---\n');
    if (combined.length > 4000) {
      combined = combined.substring(combined.length - 4000);
    }
    const systemMsg: ChatMessage = {
      id: 'sys-summarize-user',
      role: ChatRole.System,
      content: '根据以下对话中用户的发言，总结这个用户的性格特征和说话风格：\n- 说话语气（如：温柔、强势、幽默、冷淡等）\n- 常用表达方式（如：喜欢用反问、喜欢简短回复、喜欢描写动作等）\n- 行为倾向（如：主动型、被动型、进攻型、回避型等）\n- 与角色的互动模式\n\n输出格式：用2-3句话简洁描述，不要逐条列举，要融合成连贯的性格总结。',
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const userMsg: ChatMessage = {
      id: 'usr-summarize-user',
      role: ChatRole.User,
      content: '以下是用户的发言记录：\n\n' + combined,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const request: ChatRequest = {
      model: modelName,
      messages: [systemMsg, userMsg],
      temperature: 0.3,
      topP: 0.9,
      maxTokens: 512,
      stream: false
    };
    const response: ChatResponse = await this.modelService.sendChat(request);
    const summary: string = response.content.trim();
    if (summary.length === 0) {
      throw new Error('AI 返回为空');
    }
    return summary;
  }

  /**
   * 生成代写候选:AI 生成 3 条简短的用户消息候选,不持久化。
   *
   * 流程:
   * 1. 构建代写 System 指令(要求生成 3 条):身份/任务/规则 + 故事背景与发展方向(卡扩展
   *    extensions.arktavern.impres.direction) + 开场白说明 + 用户性格总结 + 全局代写引导
   * 2. 拼装请求消息(顺序):[System 指令] → [开场白消息(角色行,对话起点)] →
   *    [最近 6 条对话(角色/用户互换,现状逻辑)] → [当前角色状态(System,放最后)]
   * 3. 非流式调用 ModelService.sendChat
   * 4. 解析响应,拆分为最多 3 条候选
   *
   * 代写方向 / 开场白 / 角色状态均为可选项:缺省(或开场白与最近消息重复)时不追加任何消息,
   * 行为与旧版一致。不修改 this.messages,不持久化任何消息。
   */
  async generateImpersonateCandidates(): Promise<ImpersonateCandidate[]> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'generateImpersonateCandidates rejected: busy');
      return [];
    }
    if (this.currentChatId === undefined) {
      throw new Error('会话未初始化');
    }

    const userName: string = await this.resolveUserName();
    const charName: string = this.character !== null ? resolveCharacterDisplayName(this.character) : 'Assistant';

    const recentCount: number = Math.min(this.messages.length, 6);
    const recentMessages: ChatMessage[] = this.messages.slice(this.messages.length - recentCount);

    const swapped: ChatMessage[] = recentMessages.map((msg: ChatMessage): ChatMessage => {
      let newRole: ChatRole = msg.role;
      if (msg.role === ChatRole.User) {
        newRole = ChatRole.Assistant;
      } else if (msg.role === ChatRole.Assistant) {
        newRole = ChatRole.User;
      }
      const swappedMsg: ChatMessage = {
        id: msg.id,
        role: newRole,
        content: msg.content,
        createdAt: msg.createdAt,
        status: msg.status,
        source: msg.source
      };
      return swappedMsg;
    });

    let impersonateContent: string =
      '你是' + userName + '，是正在和' + charName + '对话的人类玩家。\n\n' +
      '任务：以' + userName + '的身份，写出 3 条各不相同、简短的下一条发言。每条都必须是一句完整、可以单独成立的话或动作，' +
      '而不是同一个意思的继续或扩充。3 条应体现不同的语气或行动，彼此是不同选择。\n\n' +
      '规则：\n' +
      '- 以' + userName + '的第一人称发言\n' +
      '- 动作用星号括起来，例如：*微笑*、*转身走开*\n' +
      '- 每条占一行，是一条完整独立的回复\n' +
      '- 不要替' + charName + '发言\n' +
      '- 不要把一个回复拆成多行';

    // ===== 故事背景与发展方向(卡扩展 extensions.arktavern.impres.direction,可选项) =====
    const directionRaw: string = this.character !== null
      ? extractImpresDirection(this.character.extensions) : '';
    let directionText: string = directionRaw;
    if (directionText.length > IMPRES_DIRECTION_MAX_CHARS) {
      directionText = directionText.substring(0, IMPRES_DIRECTION_MAX_CHARS);
    }
    if (directionText.length > 0) {
      impersonateContent += '\n\n【故事背景与发展方向】\n' + directionText;
    }

    // ===== 开场白(截断后作为对话起点消息,紧贴最近消息之前) =====
    let openingText: string = this.character !== null ? this.character.firstMessage.trim() : '';
    if (openingText.length > IMPRES_OPENING_MAX_CHARS) {
      openingText = openingText.substring(0, IMPRES_OPENING_MAX_CHARS);
    }
    // 最近消息里已含同一内容(刚开局的短会话)时不重复注入
    let openingDuplicated: boolean = false;
    if (openingText.length > 0) {
      for (let i = 0; i < recentMessages.length; i++) {
        if (recentMessages[i].content.trim() === openingText) {
          openingDuplicated = true;
          break;
        }
      }
    }
    if (openingText.length > 0 && !openingDuplicated) {
      impersonateContent += '\n\n消息序列的第一条是' + charName
        + '的故事开场白(故事开始处),仅供你理解语境,不要重复或改写它。';
    }

    // ===== 当前角色状态(会话 statusConfigJson,可选项;消息追加在请求最后) =====
    let statusText: string = '';
    if (this.currentChat !== null && this.currentChat.statusConfigJson.length > 0) {
      const entries: ChatStatusEntry[] = parseChatStatusState(this.currentChat.statusConfigJson).entries;
      const lines: string[] = [];
      for (let i = 0; i < entries.length && lines.length < IMPRES_STATUS_MAX_ENTRIES; i++) {
        const e: ChatStatusEntry = entries[i];
        if (e.value.trim().length > 0) {
          lines.push('- ' + e.name + '：' + e.value);
        }
      }
      statusText = lines.join('\n');
    }

    if (this.currentChat !== null && this.currentChat.userPersonaSummary.length > 0) {
      impersonateContent += '\n\n' + userName + '的性格特征：' + this.currentChat.userPersonaSummary;
    }
    // 用户自定义代写引导(全局),非空时追加为额外引导方向
    if (this.appPreferences !== null) {
      try {
        const guide: string = await this.appPreferences.getString(IMPRES_GUIDE_KEY, '');
        if (guide.trim().length > 0) {
          impersonateContent += '\n\n额外引导：' + guide.trim();
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load impres guide failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    impersonateContent += '\n\n格式：\n1.\n2.\n3.';

    const impersonateSystem: ChatMessage = {
      id: 'sys-impersonate',
      role: ChatRole.System,
      content: impersonateContent,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };

    const requestMessages: ChatMessage[] = [impersonateSystem];
    // [1] 开场白:作为对话起点,紧贴最近消息之前;角色行互换后为 User 角色
    if (openingText.length > 0 && !openingDuplicated) {
      const openingMsg: ChatMessage = {
        id: 'usr-impres-opening',
        role: ChatRole.User,
        content: openingText,
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.ExternalSystem
      };
      requestMessages.push(openingMsg);
    }
    // [2..] 最近 6 条(角色/用户互换逻辑不动)
    for (let i = 0; i < swapped.length; i++) {
      requestMessages.push(swapped[i]);
    }
    // [最后] 当前角色状态:追加在会话之后,最贴近"此刻"
    if (statusText.length > 0) {
      const statusMsg: ChatMessage = {
        id: 'sys-impres-status',
        role: ChatRole.System,
        content: '【当前状态】\n' + statusText,
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.ExternalSystem
      };
      requestMessages.push(statusMsg);
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }

    const effectiveSettings: EffectiveGenerationSettings =
      resolveEffectiveGenerationSettings(
        {
          temperature: config.temperature,
          topP: config.topP,
          maxOutputTokens: config.maxTokens,
          contextWindow: config.contextWindow
        },
        []
      );

    const request: ChatRequest = {
      model: modelName,
      messages: requestMessages,
      temperature: effectiveSettings.temperature !== undefined ? effectiveSettings.temperature : 0.8,
      topP: effectiveSettings.topP !== undefined ? effectiveSettings.topP : 0.9,
      maxTokens: effectiveSettings.maxOutputTokens !== undefined ? effectiveSettings.maxOutputTokens : 4096,
      stream: false
    };

    const response: ChatResponse = await this.modelService.sendChat(request);
    Logger.info(LOG_TAG, 'generateImpersonateCandidates raw response: [' + response.content + ']');
    const result: ImpersonateCandidate[] = this.parseImpersonateCandidates(response.content);
    Logger.info(LOG_TAG, 'generateImpersonateCandidates parsed count: ' + result.length);
    return result;
  }

  private parseImpersonateCandidates(raw: string): ImpersonateCandidate[] {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }

    const candidates: ImpersonateCandidate[] = [];

    const jsonStart: number = trimmed.indexOf('[');
    const jsonEnd: number = trimmed.lastIndexOf(']');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      const jsonStr: string = trimmed.substring(jsonStart, jsonEnd + 1);
      try {
        const arr: object[] = JSON.parse(jsonStr) as object[];
        if (Array.isArray(arr)) {
          for (let i = 0; i < arr.length && candidates.length < 3; i++) {
            const val: string = String(arr[i]).trim();
            if (val.length > 0) {
              const candidate: ImpersonateCandidate = {
                index: candidates.length,
                content: val
              };
              candidates.push(candidate);
            }
          }
          if (candidates.length > 0) {
            return candidates;
          }
        }
      } catch (_e) {
        // JSON parse failed, fall through
      }
    }

    const parts: string[] = trimmed.split(/\n*---\n*/);
    for (let i = 0; i < parts.length && candidates.length < 3; i++) {
      const text: string = parts[i].trim();
      if (text.length > 0) {
        const candidate: ImpersonateCandidate = {
          index: candidates.length,
          content: text
        };
        candidates.push(candidate);
      }
    }
    if (candidates.length >= 2) {
      return candidates;
    }

    candidates.length = 0;
    const lines: string[] = trimmed.split(/\n/);
    for (let i = 0; i < lines.length && candidates.length < 3; i++) {
      const text: string = lines[i].trim().replace(/^[\d]+[.)\]]\s*/, '');
      if (text.length > 0) {
        const candidate: ImpersonateCandidate = {
          index: candidates.length,
          content: text
        };
        candidates.push(candidate);
      }
    }

    if (candidates.length === 0 && trimmed.length > 0) {
      const fallback: ImpersonateCandidate = { index: 0, content: trimmed };
      candidates.push(fallback);
    }
    return candidates;
  }

  /**
   * 续写(AutoContinue):单次请求 + 完整上下文。
   *
   * 流程:
   * 1. 复用 createPresetRequestSnapshot + buildRequestMessages 构建与正常发送一致的
   *    完整上下文(预设/世界书/人物卡/记忆/宏/状态指令),保持稳定 System 前缀以命中缓存。
   * 2. 在末尾追加中文续写指令(读 CONTINUE_GUIDE_KEY,支持用户自定义引导方向),
   *    要求模型先以 {{user}} 写下一句发言,再以 {{char}} 回应这条发言。
   *    不做角色对调,避免破坏前缀缓存。
   * 3. 单次非流式 sendChat → 解析 (userText, assistantText)。
   * 4. userMsg + assistantMsg 以最终状态一次性落地并 emit。
   *
   * 指令只进瞬时请求,不落库、不进入历史消息。
   */
  async autoContinue(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'autoContinue rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    try {
      // 1. 构建完整上下文(稳定前缀,命中主线缓存)
      const snapshot: PromptPresetRequestSnapshot = await this.createPresetRequestSnapshot();
      const baseMessages: ChatMessage[] =
        await this.buildRequestMessages(snapshot.presetSystemPrompt);

      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config === null) {
        throw new Error('未配置模型');
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        throw new Error('模型名称为空');
      }

      // 2. 组装中文续写指令(默认 + 用户自定义引导),追加到消息末尾
      const userName: string = await this.resolveUserName();
      const charName: string =
        this.character !== null ? resolveCharacterDisplayName(this.character) : 'Assistant';
      // 破甲化续写指令:先锁定角色扮演状态与人设/剧情约束,再给出任务,
      // JSON 只作为输出格式放在最末尾,降低"完成任务+格式"对角色代入的稀释。
      let continueContent: string =
        '你是' + charName + '，正在与' + userName + '进行沉浸式角色扮演对话。' +
        '你拥有完整的人设、性格、语气与世界观，请始终以' + charName + '的身份说话和行动，' +
        '延续当前剧情的既定走向与氛围，按角色应该有的反应自然推进，' +
        '不跳出角色，不解释、不总结，也不以任何方式表明自己是 AI。\n\n' +
        '现在，先以' + userName + '的身份自然地说出下一句对' + charName + '说的话（一句简短完整的发言），' +
        '再以' + charName + '的身份，严格按人设与当前剧情对这句话做出符合角色性格的回应。\n\n' +
        '始终维持角色扮演状态，不得偏离' + charName + '的人设与既定剧情方向。\n\n' +
        '输出格式（仅作为结构标记，请继续以角色身份创作）：\n' +
        '{"user":"用户下一条发言","assistant":"角色对该发言的回应"}';
      if (this.appPreferences !== null) {
        try {
          const guide: string = await this.appPreferences.getString(CONTINUE_GUIDE_KEY, '');
          if (guide.trim().length > 0) {
            continueContent += '\n\n额外引导：' + guide.trim();
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'load continue guide failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      }
      const continueSystem: ChatMessage = {
        id: 'sys-auto-continue',
        role: ChatRole.System,
        content: continueContent,
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.ExternalSystem
      };
      const requestMessages: ChatMessage[] = [...baseMessages, continueSystem];

      const settings: EffectiveGenerationSettings = snapshot.generationSettings;
      const request: ChatRequest = {
        model: modelName,
        messages: requestMessages,
        temperature: settings.temperature !== undefined ? settings.temperature : 0.8,
        topP: settings.topP !== undefined ? settings.topP : 0.9,
        maxTokens: settings.maxOutputTokens !== undefined ? settings.maxOutputTokens : 4096,
        stream: false
      };

      // 3. 单次非流式调用
      const response: ChatResponse = await this.modelService.sendChat(request);
      Logger.info(LOG_TAG, 'autoContinue raw response len=' + response.content.length);
      const parsed: AutoContinueTurn | null =
        this.parseAutoContinueTurn(response.content);
      if (parsed === null || parsed.user.trim().length === 0
        || parsed.assistant.trim().length === 0) {
        callbacks.onError('续写生成失败,请重试');
        this.setState(ChatState.Failed, callbacks);
        return;
      }

      // 4. 以最终状态一次性落地用户 + 角色
      const userMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.User,
        content: parsed.user.trim(),
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.Conversation
      };
      const assistantId: string = 'msg-' + generateUuid();
      const assistantMsg: ChatMessage = {
        id: assistantId,
        role: ChatRole.Assistant,
        content: parsed.assistant.trim(),
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.Conversation,
        senderType: 'character',
        senderCharacterId: this.character !== null ? this.character.id : ''
      };

      if (this.persistenceService !== null) {
        const appendResult: AppendUserAndAssistantResult =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, userMsg, assistantMsg
          );
        this.currentSequenceNumber = appendResult.assistantSequenceNumber;
      }

      this.messages = [...this.messages, userMsg, assistantMsg];
      this.currentAssistantId = assistantId;
      this.setState(ChatState.Completed, callbacks);
      this.emitMessages(callbacks);
      this.persistChatActivity();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'autoContinue failed: ' + msg);
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError('续写生成失败,请重试');
    }
  }

  /**
   * 解析续写响应:优先 JSON 对象 {"user":...,"assistant":...},回退按关键词切分。
   * @returns 解析出的 (user, assistant) 两段;无法解析时返回 null
   */
  private parseAutoContinueTurn(raw: string): AutoContinueTurn | null {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return null;
    }
    // 优先 JSON
    const jsonStart: number = trimmed.indexOf('{');
    const jsonEnd: number = trimmed.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      const jsonStr: string = trimmed.substring(jsonStart, jsonEnd + 1);
      try {
        const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
        const u: string = typeof obj['user'] === 'string' ? obj['user'] as string : '';
        const a: string = typeof obj['assistant'] === 'string' ? obj['assistant'] as string : '';
        if (u.trim().length > 0 || a.trim().length > 0) {
          return { user: u, assistant: a };
        }
      } catch (_e) {
        // JSON 解析失败,走关键词回退
      }
    }
    // 回退:按 用户发言/角色回应 关键词切分
    const userMarkers: string[] = ['用户发言', '"user"', 'user:'];
    const assistMarkers: string[] = ['角色回应', '"assistant"', 'assistant:'];
    for (let i = 0; i < userMarkers.length; i++) {
      const ui: number = trimmed.indexOf(userMarkers[i]);
      if (ui < 0) {
        continue;
      }
      let start: number = ui + userMarkers[i].length;
      if (start < trimmed.length
        && (trimmed.charAt(start) === '：' || trimmed.charAt(start) === ':')) {
        start++;
      }
      let bestAssist: number = -1;
      let bestAssistLen: number = 0;
      for (let j = 0; j < assistMarkers.length; j++) {
        const ai: number = trimmed.indexOf(assistMarkers[j], start);
        if (ai >= 0 && (bestAssist < 0 || ai < bestAssist)) {
          bestAssist = ai;
          bestAssistLen = assistMarkers[j].length;
        }
      }
      if (bestAssist < 0) {
        continue;
      }
      const userText: string = trimmed.substring(start, bestAssist).trim();
      let asStart: number = bestAssist + bestAssistLen;
      if (asStart < trimmed.length
        && (trimmed.charAt(asStart) === '：' || trimmed.charAt(asStart) === ':')) {
        asStart++;
      }
      const assistantText: string = trimmed.substring(asStart).trim();
      if (userText.length > 0 || assistantText.length > 0) {
        return { user: userText, assistant: assistantText };
      }
    }
    return null;
  }
}
