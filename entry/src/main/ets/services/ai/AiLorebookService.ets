/**
 * AiLorebookService AI 世界书编辑服务
 *
 * 职责:
 * - 基于现有世界书条目 + 近期对话 + 用户指令,让 AI 生成世界书变更提案
 * - 支持两种模式:
 *   - extract: 从近期对话提取新出现的角色/地点/物品,提议新增条目
 *   - modify:  按用户指令增加/修改世界书条目
 * - 输出经 parseAiLorebookChangeSet 安全解析 + validateAiChangeSet 校验
 * - 不直接写入数据库(由 ViewModel 预览确认后调 LorebookService 落库)
 *
 * 请求隔离:
 * - 独立一次性请求,不进入聊天历史 / PromptBuilder / 前缀缓存链路
 * - 只发送角色无关的编辑指令 + 现有条目摘要 + 最近对话摘要
 * - 不携带 API Key / 完整聊天记录
 *
 * 分层约束:
 * - 可被 ViewModel 间接调用
 * - 不引用页面 / ViewModel 类
 * - 不直接访问存储层(通过 LorebookService)
 */

import { ModelService } from '../ModelService';
import { LorebookService } from '../LorebookService';
import { Lorebook, LorebookEntry } from '../../models/Lorebook';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { Logger } from '../../utils/Logger';
import {
  AiLorebookChangeSet,
  createEmptyAiLorebookChangeSet,
  parseAiLorebookChangeSet,
  validateAiChangeSet
} from '../../models/LorebookAiTypes';

const LOG_TAG: string = 'AiLorebook';

/** 提案生成温度(较低,提高 JSON 结构稳定性) */
const PROPOSE_TEMPERATURE: number = 0.3;
/** 提案生成 top_p */
const PROPOSE_TOP_P: number = 0.9;
/** 提案生成最大 token 数 */
const PROPOSE_MAX_TOKENS: number = 2048;
/** 最近对话取样条数 */
const RECENT_MESSAGE_SAMPLE: number = 12;

/**
 * AI 世界书操作模式。
 */
export enum AiLorebookMode {
  /** 从近期对话提取新角色/地点,只建议新增 */
  Extract = 'extract',
  /** 按用户指令增改条目 */
  Modify = 'modify'
}

/**
 * AI 世界书提案输入。
 */
export interface AiLorebookInput {
  /** 全局当前世界书(可能为 null) */
  readonly globalBook: Lorebook | null;
  /** 角色专属世界书(可能为 null) */
  readonly characterBook: Lorebook | null;
  /** 近期对话消息(按时间正序) */
  readonly recentMessages: ChatMessage[];
  /** 用户指令(extract 模式可留空) */
  readonly instruction: string;
  /** 操作模式 */
  readonly mode: AiLorebookMode;
}

/**
 * AI 世界书编辑服务。
 */
export class AiLorebookService {
  private readonly modelService: ModelService;
  private readonly lorebookService: LorebookService;

  constructor(modelService: ModelService, lorebookService: LorebookService) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
  }

  /**
   * 生成世界书变更提案。
   * 失败(模型未配置 / 请求失败 / 解析失败)返回空变更集,不抛错。
   *
   * @param input 提案输入
   * @returns 变更集(可能为空)
   */
  async proposeChanges(input: AiLorebookInput): Promise<AiLorebookChangeSet> {
    try {
      const config = await this.modelService.getCurrentConfig();
      if (config === null) {
        Logger.warn(LOG_TAG, 'proposeChanges: no current provider config');
        return createEmptyAiLorebookChangeSet();
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        Logger.warn(LOG_TAG, 'proposeChanges: current model name is empty');
        return createEmptyAiLorebookChangeSet();
      }

      const messages: ChatMessage[] = this.buildPromptMessages(input);
      const request: ChatRequest = {
        model: modelName,
        messages: messages,
        temperature: PROPOSE_TEMPERATURE,
        topP: PROPOSE_TOP_P,
        maxTokens: PROPOSE_MAX_TOKENS,
        stream: false,
        responseFormatJson: true
      };
      const response = await this.modelService.sendChat(request);
      if (response.content.length === 0) {
        Logger.warn(LOG_TAG, 'proposeChanges: empty response');
        return createEmptyAiLorebookChangeSet();
      }

      const changes: AiLorebookChangeSet | null = parseAiLorebookChangeSet(response.content);
      if (changes === null) {
        Logger.warn(LOG_TAG, 'proposeChanges: parse failed, content.len=' +
          response.content.length.toString());
        return createEmptyAiLorebookChangeSet();
      }

      const allowed: string[] = this.collectAllowedBookIds(input);
      const errors: string[] = validateAiChangeSet(changes, allowed);
      if (errors.length > 0) {
        Logger.warn(LOG_TAG, 'proposeChanges: validation errors count=' +
          errors.length.toString());
      }
      return changes;
    } catch (e) {
      Logger.warn(LOG_TAG, 'proposeChanges failed: ' + String(e));
      return createEmptyAiLorebookChangeSet();
    }
  }

  /**
   * 构建提案请求消息:
   * System(编辑规则 + JSON schema) → System(现有条目摘要) → User(近期对话 + 用户指令)。
   */
  private buildPromptMessages(input: AiLorebookInput): ChatMessage[] {
    const messages: ChatMessage[] = [];
    messages.push(createChatMessage(
      generateProposalId('sys'), ChatRole.System, this.buildSystemPrompt(input.mode), Date.now()
    ));

    const entriesSummary: string = this.buildEntriesSummary(input);
    if (entriesSummary.length > 0) {
      messages.push(createChatMessage(
        generateProposalId('ctx'), ChatRole.System, entriesSummary, Date.now()
      ));
    }

    const userContent: string = this.buildUserContent(input);
    messages.push(createChatMessage(
      generateProposalId('usr'), ChatRole.User, userContent, Date.now()
    ));
    return messages;
  }

  /**
   * 构建 System 编辑规则提示词。
   */
  private buildSystemPrompt(mode: AiLorebookMode): string {
    const modeRule: string = mode === AiLorebookMode.Extract
      ? '模式 extract:只从近期对话中提取**新出现且尚未记录**的角色、地点、物品、组织等设定,'
        + '生成 adds;不得修改或删除现有条目。'
      : '模式 modify:严格按用户指令增加/修改条目。'
        + '若用户要求修改某条目,尽量通过 updates(保留 entryId)实现,而不是删除后新增。';

    return '你是世界书(Lorebook)编辑助手。你的任务是分析现有世界书条目和近期对话,'
      + '按用户要求生成世界书变更提案。\n\n'
      + modeRule + '\n\n'
      + '输出必须是一个 JSON 对象,不要输出任何解释性文字,格式如下:\n'
      + '{\n'
      + '  "adds": [\n'
      + '    {\n'
      + '      "lorebookId": "目标世界书ID(必须来自下面提供的书籍)",\n'
      + '      "name": "条目名称",\n'
      + '      "keys": ["关键词1", "关键词2"],\n'
      + '      "content": "条目内容(角色/地点/物品设定,50-300字左右,简洁具体)",\n'
      + '      "position": "BeforeCharacter",\n'
      + '      "priority": 0,\n'
      + '      "constant": false\n'
      + '    }\n'
      + '  ],\n'
      + '  "updates": [\n'
      + '    {\n'
      + '      "lorebookId": "世界书ID",\n'
      + '      "entryId": "条目ID",\n'
      + '      "name": "新名称(可选)",\n'
      + '      "keys": ["新关键词(可选)"],\n'
      + '      "content": "新内容(可选)",\n'
      + '      "position": "BeforeCharacter",\n'
      + '      "priority": 1\n'
      + '    }\n'
      + '  ],\n'
      + '  "deletes": [\n'
      + '    { "lorebookId": "世界书ID", "entryId": "条目ID" }\n'
      + '  ]\n'
      + '}\n\n'
      + '规则:\n'
      + '- 只操作下面提供的世界书中的条目,lorebookId 必须来自提供的书籍 ID。\n'
      + '- 非恒定条目(constant=false)必须提供至少一个关键词(keys)。\n'
      + '- 不要重复已有条目(除非用户明确要求更新)。\n'
      + '- 没有需要变更的内容时,输出 {"adds":[],"updates":[],"deletes":[]}。';
  }

  /**
   * 构建现有条目摘要(System 消息)。
   */
  private buildEntriesSummary(input: AiLorebookInput): string {
    const parts: string[] = [];
    if (input.characterBook !== null) {
      parts.push(this.formatBookSummary(input.characterBook, true));
    }
    if (input.globalBook !== null) {
      parts.push(this.formatBookSummary(input.globalBook, false));
    }
    if (parts.length === 0) {
      return '';
    }
    return '【现有世界书条目】\n' + parts.join('\n\n');
  }

  private formatBookSummary(book: Lorebook, isCharacterBook: boolean): string {
    const label: string = isCharacterBook ? '角色专属世界书' : '全局世界书';
    const lines: string[] = [];
    lines.push('## ' + label + '(ID: ' + book.id + ')' + (book.name.length > 0 ? ' 名称: ' + book.name : ''));
    if (book.entries.length === 0) {
      lines.push('(无条目)');
    } else {
      for (let i = 0; i < book.entries.length; i++) {
        const e: LorebookEntry = book.entries[i];
        const contentPreview: string = e.content.length > 200
          ? e.content.substring(0, 200) + '...' : e.content;
        const keysText: string = e.keys.join('、');
        lines.push('- 条目ID: ' + e.id
          + ' | 名称: ' + e.name
          + (e.constant ? ' [恒定]' : '')
          + (keysText.length > 0 ? ' | 关键词: ' + keysText : '')
          + ' | 内容: ' + contentPreview);
      }
    }
    return lines.join('\n');
  }

  /**
   * 构建 User 指令消息(近期对话 + 用户要求)。
   */
  private buildUserContent(input: AiLorebookInput): string {
    const parts: string[] = [];
    if (input.recentMessages.length > 0) {
      parts.push('【近期对话】\n' + this.formatRecentMessages(input.recentMessages));
    }
    if (input.mode === AiLorebookMode.Extract) {
      const instruction: string = input.instruction.trim().length > 0
        ? input.instruction.trim()
        : '请从近期对话中提取新出现的角色、地点、物品等设定,新增到世界书。';
      parts.push('【用户要求】\n' + instruction);
    } else {
      const instruction: string = input.instruction.trim();
      if (instruction.length > 0) {
        parts.push('【用户要求】\n' + instruction);
      } else {
        parts.push('【用户要求】\n请根据现有条目与近期对话,补充或优化世界书条目。');
      }
    }
    return parts.join('\n\n');
  }

  private formatRecentMessages(messages: ChatMessage[]): string {
    const lines: string[] = [];
    // 只取最近 RECENT_MESSAGE_SAMPLE 条 User/Assistant 非空消息
    const sampled: ChatMessage[] = [];
    for (let i = messages.length - 1; i >= 0 && sampled.length < RECENT_MESSAGE_SAMPLE; i--) {
      const m: ChatMessage = messages[i];
      if ((m.role === ChatRole.User || m.role === ChatRole.Assistant) && m.content.length > 0) {
        sampled.push(m);
      }
    }
    for (let i = sampled.length - 1; i >= 0; i--) {
      const m: ChatMessage = sampled[i];
      const roleText: string = m.role === ChatRole.User ? '用户' : '角色';
      const contentPreview: string = m.content.length > 500
        ? m.content.substring(0, 500) + '...' : m.content;
      lines.push(roleText + ': ' + contentPreview);
    }
    return lines.join('\n');
  }

  private collectAllowedBookIds(input: AiLorebookInput): string[] {
    const ids: string[] = [];
    if (input.characterBook !== null) {
      ids.push(input.characterBook.id);
    }
    if (input.globalBook !== null) {
      ids.push(input.globalBook.id);
    }
    return ids;
  }
}

/**
 * 生成提案消息 ID(避免与聊天消息冲突)。
 */
function generateProposalId(prefix: string): string {
  return 'ai-lb-' + prefix + '-' + Date.now().toString();
}
