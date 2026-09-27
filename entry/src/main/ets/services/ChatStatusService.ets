/**
 * ChatStatusService 角色状态簇(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - 声明式状态 Schema:从角色卡解析、随会话同步、字段骨架填充
 * - 状态读写:updateStatusState 归一(锁字段/丢弃未声明字段)、AI 输出合并(computeMergedStatus)
 * - 持久化与通知:persistStatusConfig / emitStatusChanged
 * - 一次性状态请求:AI 生成字段 / 按指令修改状态(流式 + JSON 兜底解析)
 * - 提示词段:状态当前值消息、稳定段文本与一次性指令文本
 *
 * 依赖与宿主(ArkTS 说明):
 * - 本类**自带状态**(currentStatusState / statusSchema / 两个进行中标志 / 指令开关随类存活);
 *   ChatService 仅保留同名薄包装与调用点。
 * - 三服务经构造函数注入(只读引用,与 ChatService 同批装配);
 *   跨类所需的会话状态与宿主私有能力经 ChatStatusHost 回调读写——与搬运前 this.xxx 语义一致。
 * - 日志 tag 由 ChatService 改为 ChatStatusService(仅日志来源标注变化);
 *   6 个原 private 方法因跨类调用在搬出后改为 public(方法体未动,已记录)。
 */

import { ChatMessage, createChatMessage, mergeChatMessage } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import { Character, buildCharacterSystemContent } from '../models/Character';
import { ChatRequestOptions } from '../models/ChatRequest';
import {
  ChatStreamCallbacks,
  ChatDelta,
  ChatStreamResult
} from '../models/ChatStreamTypes';
import { NetworkError } from '../models/NetworkError';
import {
  ChatStatusState,
  ChatStatusEntry,
  ChatStatusSchemaEntry,
  createEmptyChatStatusState,
  createChatStatusEntry,
  serializeChatStatusState,
  parseChatStatusState,
  extractStatusSchema
} from '../models/ChatStatusState';
import { extractStatusBlock } from '../parser/ChatStatusBlockParser';
import {
  STATUS_INSTRUCTION_PREFS_KEY,
  buildStatusValuesText,
  buildStatusRuleText,
  buildStatusInstructionText
} from './ChatTextContract';
import { ModelService } from './ModelService';
import { ChatPersistenceService } from './ChatPersistenceService';
import { AppPreferences } from '../storage/AppPreferences';
import { ChatServiceCallbacks } from '../models/ChatServiceContract';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatStatusService';

// ===== 模块级纯函数(原 ChatService 文件级函数,逐字搬出;仅本类使用) =====

/**
 * CHAT-STATUS-1A: 按字段名在条目列表中查找(精确匹配)。
 * @returns 找到的条目,未找到返回 null
 */
function findStatusEntryByName(
  entries: ChatStatusEntry[],
  name: string
): ChatStatusEntry | null {
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].name === name) {
      return entries[i];
    }
  }
  return null;
}

/**
 * CHAT-STATUS-1A: 尝试把整段响应作为 JSON 解析出状态字段(兜底)。
 * 处理:
 * - 纯 JSON 对象 {"字段名":"值"}
 * - 单层包装 {"status": {...}} / {"data": {...}}
 * - 双重编码 "{\"字段名\":\"值\"}"
 */
function parseStatusJsonWhole(content: string): ChatStatusEntry[] {
  const trimmed: string = stripFencesForStatus(content);
  if (trimmed.length === 0) {
    return [];
  }
  let parsed: Object | null = tryParseJson(trimmed);
  // 双重编码:解析结果是字符串,再解析一次
  if (parsed !== null && typeof parsed === 'string') {
    parsed = tryParseJson(parsed as string);
  }
  if (parsed === null || typeof parsed !== 'object') {
    return [];
  }
  const root: Record<string, Object> = parsed as Record<string, Object>;
  const entries: ChatStatusEntry[] = collectScalarEntries(root);
  if (entries.length > 0) {
    return entries;
  }
  // 单层包装:取第一个对象值键的内层
  const keys: string[] = Object.keys(root);
  for (let i = 0; i < keys.length; i++) {
    const val: Object | undefined = root[keys[i]];
    if (val !== null && typeof val === 'object') {
      const innerEntries: ChatStatusEntry[] = collectScalarEntries(val as Record<string, Object>);
      if (innerEntries.length > 0) {
        return innerEntries;
      }
    }
  }
  return [];
}

function tryParseJson(text: string): Object | null {
  try {
    return JSON.parse(text) as Object;
  } catch (e) {
    return null;
  }
}

function collectScalarEntries(obj: Record<string, Object>): ChatStatusEntry[] {
  const entries: ChatStatusEntry[] = [];
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    const name: string = keys[i].trim();
    if (name.length === 0) {
      continue;
    }
    const raw: Object | undefined = obj[keys[i]];
    const value: string = statusScalarToString(raw);
    if (value.length === 0) {
      continue;
    }
    entries.push(createChatStatusEntry(name, value, false, false));
  }
  return entries;
}

function statusScalarToString(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  if (typeof raw === 'string') {
    return (raw as string).trim();
  }
  if (typeof raw === 'number') {
    return String(raw as number);
  }
  if (typeof raw === 'boolean') {
    return String(raw as boolean);
  }
  return '';
}

function stripFencesForStatus(text: string): string {
  let s: string = text.trim();
  if (s.startsWith('```')) {
    const nl: number = s.indexOf('\n');
    s = nl >= 0 ? s.substring(nl + 1) : s.substring(3);
  }
  if (s.endsWith('```')) {
    s = s.substring(0, s.length - 3);
  }
  return s.trim();
}

/** 状态服务依赖(全部为只读引用,null 表示未装配) */
export interface ChatStatusDeps {
  /** 模型服务(一次性状态请求的流式调用) */
  modelService: ModelService;
  /** 会话持久化服务(状态 JSON 落库) */
  persistenceService: ChatPersistenceService | null;
  /** 全局偏好(状态指令开关读写) */
  appPreferences: AppPreferences | null;
}

/**
 * 宿主回调:会话状态读取、宿主能力与回调读取。
 * 与搬运前 this.xxx 的读取时机一致,不含业务逻辑。
 */
export interface ChatStatusHost {
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 是否正在生成(与主线/代写/续写互斥) */
  isBusy: () => boolean;
  /** 当前角色卡(可能为 null) */
  getCharacter: () => Character | null;
  /** 当前会话(可能为 null) */
  getCurrentChat: () => Chat | null;
  /** 回写宿主缓存的当前会话(状态 JSON 落库后刷新) */
  setCurrentChat: (chat: Chat | null) => void;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前消息列表(读取即最新;一次性请求附加上下文用) */
  getMessages: () => ChatMessage[];
  /** 最近一次回调(状态变更通知用) */
  getLastCallbacks: () => ChatServiceCallbacks | null;
}

export class ChatStatusService {
  private readonly modelService: ModelService;
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly appPreferences: AppPreferences | null;
  private readonly host: ChatStatusHost;

  // ===== 自带状态(CHAT-STATUS-1A,原 ChatService 字段随迁) =====
  /** 当前会话的角色状态(随会话切换加载,AI 回复后合并更新) */
  private currentStatusState: ChatStatusState = createEmptyChatStatusState();
  /** CHAT-STATUS-1A: 是否请求下一次回复重新生成/优化字段(点击"AI 生成"按钮设置) */
  private statusFieldGenerationRequested: boolean = false;
  /** CHAT-STATUS-1A: 是否正在执行一次性的字段生成请求(防止并发) */
  private statusGenerationInProgress: boolean = false;
  /**
   * 声明式状态 Schema(arktavern-card-extensions v1):角色卡声明的允许状态字段集合。
   * 由 character.extensions.arktavern.status.fields 解析;为空表示状态功能整体禁用。
   */
  private statusSchema: ChatStatusSchemaEntry[] = [];
  /**
   * 状态输出指令开关。
   * true=向模型注入状态输出指令(AI 回复时附带状态 JSON);
   * false=不注入状态指令,AI 只返回纯正文(不返回状态 JSON)。
   * 可由用户在记忆管理页手动切换。默认 true。
   */
  private statusInstructionEnabled: boolean = true;

  constructor(deps: ChatStatusDeps, host: ChatStatusHost) {
    this.modelService = deps.modelService;
    this.persistenceService = deps.persistenceService;
    this.appPreferences = deps.appPreferences;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  private get currentChat(): Chat | null {
    return this.host.getCurrentChat();
  }

  private set currentChat(value: Chat | null) {
    this.host.setCurrentChat(value);
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private get lastCallbacks(): ChatServiceCallbacks | null {
    return this.host.getLastCallbacks();
  }

  private isBusy(): boolean {
    return this.host.isBusy();
  }

  // ===== 供宿主委托的补充入口(非搬运代码) =====

  /** 复位一次性「重新生成字段」请求(流式完成但未解析到状态字段时由宿主调用) */
  resetFieldGenerationRequest(): void {
    this.statusFieldGenerationRequested = false;
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  // ===== CHAT-STATUS-1A: 角色状态 =====

  /**
   * 获取当前会话的角色状态(只读)。
   */
  getChatStatusState(): ChatStatusState {
    return this.currentStatusState;
  }

  /**
   * 返回当前角色卡的状态 Schema JSON(arktavern-card-extensions v1)。
   * 空数组 JSON '[]'(无声明/状态功能禁用)。
   */
  getStatusSchemaJson(): string {
    return JSON.stringify(this.statusSchema);
  }

  /**
   * CHAT-STATUS-1A: 请求下一次回复重新生成/优化角色状态字段。
   * 由"AI 生成"按钮调用,在下一轮 buildStatusInstruction 时生效,回复完成后复位。
   */
  requestStatusFieldGeneration(): void {
    this.statusFieldGenerationRequested = true;
  }

  /**
   * 更新角色状态(声明式 v1):以 next 覆盖非 locked 已声明字段的值,其余字段值保留。
   * - 未声明字段一律丢弃(不能新增);已声明字段不能删除/改名
   * - locked 字段值不接受变更;清空 = 置空值展示
   * - 无 schema 声明 → 状态整体为空(禁用)
   * 校验、持久化并通知 UI。
   */
  updateStatusState(next: ChatStatusState): void {
    this.currentStatusState = this.normalizeStatusForSchema(next);
    this.persistStatusConfig();
    this.emitStatusChanged(this.lastCallbacks);
  }

  /** 声明式归一:把待更新状态重塑为「schema 声明的字段集合」,过滤/锁定规则见 updateStatusState */
  private normalizeStatusForSchema(next: ChatStatusState): ChatStatusState {
    const schema: ChatStatusSchemaEntry[] = this.statusSchema;
    if (schema.length === 0) {
      return createEmptyChatStatusState();
    }
    const cur: ChatStatusEntry[] = this.currentStatusState.entries;
    const nextEntries: ChatStatusEntry[] = next.entries;
    const out: ChatStatusEntry[] = [];
    for (let i = 0; i < schema.length; i++) {
      const s: ChatStatusSchemaEntry = schema[i];
      const curE: ChatStatusEntry | null = findStatusEntryByName(cur, s.name);
      const nextE: ChatStatusEntry | null = findStatusEntryByName(nextEntries, s.name);
      let val: string = '';
      let fromUser: boolean = false;
      if (s.locked) {
        val = curE !== null ? curE.value : '';
        fromUser = curE !== null ? curE.fromUser : false;
      } else if (nextE !== null) {
        val = nextE.value;
        fromUser = nextE.fromUser;
      } else if (curE !== null) {
        val = curE.value;
        fromUser = curE.fromUser;
      }
      out.push(createChatStatusEntry(s.name, val, fromUser, s.locked));
    }
    return { entries: out };
  }

  /**
   * 从当前会话的 statusConfigJson 同步内存状态。
   * 会话初始化 / 切换 / 新建后调用。
   */
  syncStatusStateFromCurrentChat(): void {
    if (this.currentChat !== null) {
      this.currentStatusState = parseChatStatusState(this.currentChat.statusConfigJson);
    } else {
      this.currentStatusState = createEmptyChatStatusState();
    }
    // 声明式 v1:有 schema 但状态尚未生成(新会话/首轮)时,用声明字段的空值骨架填充,
    // 保证状态入口/面板在首次 AI 输出前即可显示全部声明字段(空值待填)。
    this.seedStatusFromSchema();
  }

  /** 状态骨架与声明联动:无 schema 清空(禁用);有 schema 且骨架空时用空值字段初始化 */
  private seedStatusFromSchema(): void {
    if (this.statusSchema.length === 0) {
      if (this.currentStatusState.entries.length !== 0) {
        this.currentStatusState = createEmptyChatStatusState();
      }
      return;
    }
    if (this.currentStatusState.entries.length > 0) {
      return;
    }
    const entries: ChatStatusEntry[] = [];
    for (let i = 0; i < this.statusSchema.length; i++) {
      const s: ChatStatusSchemaEntry = this.statusSchema[i];
      entries.push(createChatStatusEntry(s.name, '', false, s.locked));
    }
    this.currentStatusState = { entries: entries };
  }

  /**
   * 从当前角色卡解析声明式状态 Schema(extensions.arktavern.status.fields)。
   * 空数组 = 状态功能整体禁用(不注入指令、不显示入口、getState 为空)。
   */
  syncStatusSchemaFromCharacter(): void {
    if (this.character !== null) {
      this.statusSchema = extractStatusSchema(this.character.extensions);
    } else {
      this.statusSchema = [];
    }
  }

  /**
   * 合并 AI 本轮输出的状态字段(纯计算,不修改状态)——声明式 v1。
   * - 只保留 statusSchema 声明过的字段(未声明字段一律忽略,AI 无权新增/删除)
   * - locked 字段:禁止 AI 更新值,始终保留现值
   * - 非 locked 声明字段:用 AI 本轮输出更新;本轮未输出则保留现值(骨架不随轮次消失)
   * - 结果按 schema 顺序重建,刷新 fromUser 之外的部分
   */
  private computeMergedStatus(parsedEntries: ChatStatusEntry[]): ChatStatusState {
    const schema: ChatStatusSchemaEntry[] = this.statusSchema;
    const oldEntries: ChatStatusEntry[] = this.currentStatusState.entries;
    const nextEntries: ChatStatusEntry[] = [];
    for (let i = 0; i < schema.length; i++) {
      const s: ChatStatusSchemaEntry = schema[i];
      const cur: ChatStatusEntry | null = findStatusEntryByName(oldEntries, s.name);
      const existedBefore: boolean = cur !== null;
      if (s.locked) {
        // 锁定字段:值恒定,保留现值(无则置空占位展示)
        nextEntries.push(createChatStatusEntry(s.name, existedBefore ? cur!.value : '', existedBefore ? cur!.fromUser : false, true));
        continue;
      }
      const match: ChatStatusEntry | null = findStatusEntryByName(parsedEntries, s.name);
      if (match !== null) {
        nextEntries.push(createChatStatusEntry(s.name, match.value, existedBefore ? cur!.fromUser : false, s.locked));
      } else if (existedBefore) {
        nextEntries.push(createChatStatusEntry(s.name, cur!.value, cur!.fromUser, s.locked));
      } else {
        nextEntries.push(createChatStatusEntry(s.name, '', false, s.locked));
      }
    }
    return { entries: nextEntries };
  }

  /**
   * 合并 AI 本轮输出的状态字段并持久化、通知 UI(流式回复完成路径)。
   */
  applyStatusUpdate(
    parsedEntries: ChatStatusEntry[],
    callbacks: ChatServiceCallbacks
  ): void {
    this.currentStatusState = this.computeMergedStatus(parsedEntries);
    // 消耗一次性"重新生成字段"请求
    this.statusFieldGenerationRequested = false;
    this.persistStatusConfig();
    this.emitStatusChanged(callbacks);
  }

  /**
   * CHAT-STATUS-1A: 立即生成/优化角色状态字段(点击"AI 生成"按钮,独立的一次性请求)。
   *
   * - 不经过正常聊天消息流,不写入聊天历史
   * - 用角色信息 + 状态生成指令构造一次短请求,流式完成后解析状态块并合并
   * - 返回合并后的状态;失败返回 null(不修改现有状态)
   *
   * @returns 合并后的状态,失败返回 null
   */
  async generateStatusFieldsNow(): Promise<ChatStatusState | null> {
    if (this.disposed) {
      return null;
    }
    if (this.isBusy()) {
      return null;
    }
    if (this.statusGenerationInProgress) {
      return null;
    }
    if (this.character === null) {
      return null;
    }
    if (this.modelService === null) {
      return null;
    }
    this.statusGenerationInProgress = true;
    try {
      const messages: ChatMessage[] = [];
      const systemContent: string = buildCharacterSystemContent(this.character);
      if (systemContent.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, systemContent, Date.now()));
      }
      // 强制使用"重新生成"指令(优先于状态维护指令)
      const wasRequested: boolean = this.statusFieldGenerationRequested;
      this.statusFieldGenerationRequested = true;
      const instruction: string = this.buildStatusInstruction();
      this.statusFieldGenerationRequested = wasRequested;
      if (instruction.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, instruction, Date.now()));
      }
      // 附上最近的对话上下文,让字段贴合当前剧情
      this.appendRecentContextForStatus(messages);
      messages.push(createChatMessage(generateUuid(), ChatRole.User, '请根据角色信息与对话内容生成角色状态。', Date.now()));

      const options: ChatRequestOptions = {
        temperature: 0.6,
        topP: 1.0,
        maxTokens: 512,
        stream: true,
        responseFormatJson: true
      };

      const parseContent = (content: string): ChatStatusState | null => {
        const extraction = extractStatusBlock(content);
        if (extraction.parsedEntries.length === 0) {
          Logger.warn(LOG_TAG, 'generateStatusFieldsNow: no valid status block parsed, content=' +
            content.substring(0, 200));
          return null;
        }
        this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
        this.statusFieldGenerationRequested = false;
        this.persistStatusConfig();
        return this.currentStatusState;
      };
      return await this.runStatusOneShotStream(
        messages, options, 'generateStatusFieldsNow', parseContent
      );
    } finally {
      this.statusGenerationInProgress = false;
    }
  }

  /**
   * CHAT-STATUS-1A: 按用户指令立即修改角色状态字段(「AI 修改状态」,独立的一次性请求)。
   *
   * - 不经过正常聊天消息流,不写入聊天历史
   * - 用角色信息 + 标准状态输出指令 + 用户指令构造一次短请求,流式完成后解析状态块并合并
   * - 返回合并后的状态;失败返回 null(不修改现有状态)
   *
   * 说明:不使用 responseFormatJson(强制 JSON 会与 <|status|> 标记块指令冲突,
   * 导致模型输出不可解析),让模型按标记块格式输出,并提供整段 JSON 兜底解析。
   *
   * @param prompt 用户修改指令(如"把地点改成森林")
   * @returns 合并后的状态,失败返回 null
   */
  async modifyStatusWithPrompt(prompt: string): Promise<ChatStatusState | null> {
    if (this.disposed) {
      return null;
    }
    if (this.isBusy()) {
      return null;
    }
    if (this.statusGenerationInProgress) {
      return null;
    }
    if (this.character === null) {
      return null;
    }
    if (this.modelService === null) {
      return null;
    }
    const trimmedPrompt: string = prompt.trim();
    if (trimmedPrompt.length === 0) {
      return null;
    }
    this.statusGenerationInProgress = true;
    try {
      const messages: ChatMessage[] = [];
      const systemContent: string = buildCharacterSystemContent(this.character);
      if (systemContent.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, systemContent, Date.now()));
      }
      // 使用标准"维护字段"指令(临时忽略一次性"重新生成"请求,避免指令冲突)
      const wasRequested: boolean = this.statusFieldGenerationRequested;
      this.statusFieldGenerationRequested = false;
      const instruction: string = this.buildStatusInstruction();
      this.statusFieldGenerationRequested = wasRequested;
      if (instruction.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, instruction, Date.now()));
      }
      this.appendRecentContextForStatus(messages);
      messages.push(createChatMessage(
        generateUuid(),
        ChatRole.User,
        '请按以下要求修改角色状态,并输出更新后的完整状态块:\n' + trimmedPrompt,
        Date.now()
      ));

      const options: ChatRequestOptions = {
        temperature: 0.6,
        topP: 1.0,
        maxTokens: 512,
        stream: true
      };

      const parseContent = (content: string): ChatStatusState | null => {
        const extraction = extractStatusBlock(content);
        if (extraction.parsedEntries.length === 0) {
          // 兜底:若标记块/围栏/裸 JSON 均未解析出字段,尝试把整段响应作为 JSON 对象解析
          const fallbackEntries: ChatStatusEntry[] = parseStatusJsonWhole(content);
          if (fallbackEntries.length > 0) {
            this.currentStatusState = this.computeMergedStatus(fallbackEntries);
            this.persistStatusConfig();
            return this.currentStatusState;
          }
          Logger.warn(LOG_TAG, 'modifyStatusWithPrompt: no valid status block parsed');
          return null;
        }
        this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
        this.persistStatusConfig();
        return this.currentStatusState;
      };
      return await this.runStatusOneShotStream(
        messages, options, 'modifyStatusWithPrompt', parseContent
      );
    } finally {
      this.statusGenerationInProgress = false;
    }
  }

  /**
   * 状态一次性请求公共骨架:Promise/settled 封装 + 流式调用与异常兜底。
   * onComplete 的解析逻辑由调用方以 parseContent 提供(返回合并后的状态或 null)。
   */
  private runStatusOneShotStream(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    logPrefix: string,
    parseContent: (content: string) => ChatStatusState | null
  ): Promise<ChatStatusState | null> {
    return new Promise<ChatStatusState | null>((resolve: Function): void => {
      let settled: boolean = false;
      const finish = (result: ChatStatusState | null): void => {
        if (!settled) {
          settled = true;
          resolve(result);
        }
      };
      const callbacks: ChatStreamCallbacks = {
        onDelta: (_delta: ChatDelta): void => {
          // 用 onComplete 的 result.content 做最终解析,忽略中间 delta
        },
        onComplete: (result: ChatStreamResult): void => {
          finish(parseContent(result.content));
        },
        onError: (e: NetworkError): void => {
          Logger.warn(LOG_TAG, logPrefix + ': stream error=' +
            (e.message !== undefined ? e.message : String(e)));
          finish(null);
        }
      };
      try {
        this.modelService!.streamCurrentChat(messages, options, callbacks);
      } catch (e) {
        finish(null);
      }
    });
  }

  /**
   * CHAT-STATUS-1A: 把最近的用户/助手对话按正序追加到消息列表末尾(供状态生成使用)。
   * 最多取最近 6 条非空对话,跳过 System 消息。
   */
  private appendRecentContextForStatus(messages: ChatMessage[]): void {
    const MAX_RECENT: number = 6;
    const recent: ChatMessage[] = [];
    for (let i = this.messages.length - 1; i >= 0 && recent.length < MAX_RECENT; i--) {
      const m: ChatMessage = this.messages[i];
      if ((m.role === ChatRole.User || m.role === ChatRole.Assistant) && m.content.length > 0) {
        recent.push(m);
      }
    }
    for (let i = recent.length - 1; i >= 0; i--) {
      messages.push(createChatMessage(generateUuid(), recent[i].role, recent[i].content, Date.now()));
    }
  }

  /**
   * 持久化当前状态到当前会话(fire-and-forget)。
   */
  private persistStatusConfig(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const chatId: string = this.currentChatId;
    const json: string = serializeChatStatusState(this.currentStatusState);
    this.persistenceService.updateChatStatusConfig(chatId, json).then((updated: Chat): void => {
      this.currentChat = updated;
    }).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'persistStatusConfig failed: '
        + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 通知角色状态变更。
   */
  private emitStatusChanged(callbacks: ChatServiceCallbacks | null): void {
    if (callbacks === null || callbacks.onStatusChanged === undefined) {
      return;
    }
    try {
      callbacks.onStatusChanged(this.currentStatusState);
    } catch (e) {
      Logger.warn(LOG_TAG, 'onStatusChanged threw: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 设置状态输出指令开关。
   * @param enabled true=注入状态指令(AI 返回状态 JSON);false=不注入,AI 只返回纯正文
   */
  setStatusInstructionEnabled(enabled: boolean): void {
    this.statusInstructionEnabled = enabled;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(STATUS_INSTRUCTION_PREFS_KEY, enabled ? 'true' : 'false')
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  /**
   * 获取状态输出指令开关状态。
   */
  isStatusInstructionEnabled(): boolean {
    return this.statusInstructionEnabled;
  }

  async loadStatusInstructionPref(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const val: string = await this.appPreferences.getString(STATUS_INSTRUCTION_PREFS_KEY, 'true');
      this.statusInstructionEnabled = val !== 'false';
    } catch (_e) {
      this.statusInstructionEnabled = true;
    }
  }

  /**
   * CHAT-STATUS-1A: 追加角色状态**当前值** system message。
   *
   * 位置固定为请求的**最后一条**(不再依赖"最后一个 system 消息"这种数据相关的位置):
   * 该段每轮都可能变化(模型更新 / 卡片界面 setState / 一键重新生成),
   * 只有钉在最末,它之前的稳定前缀(含整段对话历史)才能持续命中缓存。
   *
   * 格式要求与字段清单已拆到 PromptBuilder 的 StatusRule 稳定段,此处只带当前值。
   */
  appendStatusValuesMessage(messages: ChatMessage[]): ChatMessage[] {
    // 状态输出指令开关:关闭时不注入状态指令,AI 只返回纯正文(不返回状态 JSON)
    if (!this.statusInstructionEnabled) {
      return messages;
    }
    const values: string = buildStatusValuesText(this.statusSchema, this.currentStatusState.entries);
    if (values.length === 0) {
      return messages;
    }
    const valuesMessage: ChatMessage = mergeChatMessage(
      createChatMessage(generateUuid(), ChatRole.System, values, Date.now()),
      {
        source: ChatMessageSource.StatusValues,
        sourceName: '角色状态当前值'
      }
    );
    const result: ChatMessage[] = messages.slice();
    result.push(valuesMessage);
    return result;
  }

  /**
   * 构建状态**稳定段**文本(格式规则 + 字段清单,不含当前值),供 PromptBuilder 注入稳定前缀。
   * 关闭状态指令或无可用字段时返回空串(PromptBuilder 据此不产生段)。
   */
  buildStatusRule(): string {
    if (!this.statusInstructionEnabled) {
      return '';
    }
    return buildStatusRuleText(this.statusSchema);
  }

  /**
   * 构建状态输出指令文本(规则与当前值合并,声明式 v1)。
   * 仅供**一次性请求**使用(重新生成字段 / AI 修改状态),这类请求不走前缀缓存。
   * - 无声明 schema → 返回空字符串(不注入状态指令,状态功能整体禁用)
   * - 请求刷新字段 → 让 AI 只输出所有已声明字段的最新值(一次性请求)
   * - 正常路径 → 让 AI 在正文后输出状态块,只更新已声明字段,禁止增删字段
   */
  private buildStatusInstruction(): string {
    return buildStatusInstructionText(this.statusSchema, this.currentStatusState.entries, this.statusFieldGenerationRequested);
  }
}