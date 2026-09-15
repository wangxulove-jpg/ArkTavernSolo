/**
 * PromptBuilder 提示词构建器
 *
 * 统一构建发送给模型的最终请求消息。
 * 将角色提示词、对话示例、世界书注入和聊天历史按固定顺序组装。
 *
 * 职责:
 * - 接收角色、世界书和聊天消息
 * - 动态匹配世界书条目
 * - 构建最终 ChatMessage[]
 * - 不修改传入的原始消息数组
 * - 不保存状态
 * - 不访问页面或网络层
 *
 * 固定消息顺序:
 * PromptPreset → BeforeCharacter → Character → AfterCharacter
 *   → DialogueExamples → MemorySummary → Conversation → PostHistory
 *
 * V2 字段处理:
 * - character.systemPrompt 非空时覆盖默认 Character 段;
 *   若包含 {{original}},替换为默认组合内容(name/description/personality/scenario)
 * - character.mesExample 非空时作为 DialogueExamples 段(对话示例)
 * - character.postHistoryInstructions 非空时作为 PostHistory 段;
 *   若包含 {{original}},替换为空字符串(当前无全局 Post-History 概念)
 * - character.characterBookId 关联的角色专属 Lorebook 由调用方加载为 characterBook,
 *   聊天只注入角色绑定的这本书(不再有全局书籍参与)
 * - tags / creator / characterVersion / creatorNotes 不进入 Prompt
 */

import {
  Character,
  buildCharacterSystemContent,
  buildDefaultCharacterSystemContent,
  resolveCharacterDisplayName
} from '../models/Character';
import { Lorebook, LorebookEntry, LorebookPosition, LorebookActivationMode } from '../models/Lorebook';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MacroContext, MacroContextBuilder } from '../models/MacroContext';
import {
  PromptSegment,
  PromptSegmentPosition,
  createPromptSegment,
  sortSegments
} from '../models/PromptSegment';
import { ChatMemory } from '../models/ChatMemory';
import { Persona } from '../models/Persona';
import { PersonaPosition } from '../models/PersonaPosition';
import { LorebookService } from './LorebookService';
import { MacroReplacer } from './MacroReplacer';

/** mes_example 分隔符,与 SillyTavern 规范一致 */
const EXAMPLE_SEPARATOR: string = '<START>';

/**
 * v12 多层记忆注入参数。
 * 由调用方从 MemoryService.getMultiLayerInjectionContext 获取后传入。
 * 提供此字段时,优先使用分层注入;否则回退到 memorySummary 单段注入。
 */
export interface MemoryLayersInjection {
  /** Core 记忆(高优先级,全量注入) */
  core: ChatMemory[];
  /** Chapter 记忆(已按时间倒序排列,取最近 N 个) */
  chapter: ChatMemory[];
  /** Rolling 记忆(最近 1 条) */
  rolling: ChatMemory[];
  /** Legacy 记忆(旧数据迁移) */
  legacy: ChatMemory[];
}

/**
 * Prompt 构建上下文。
 */
export interface PromptBuildContext {
  /** 当前角色(可选) */
  character?: Character;
  /** 角色专属世界书(可选,通过 character.characterBookId 加载;聊天只注入这本书) */
  characterBook?: Lorebook;
  /** 当前聊天消息列表 */
  messages: ChatMessage[];
  /** 宏替换上下文(可选,提供时对最终消息执行宏替换) */
  macroContext?: MacroContext;
  /** Preset 附加 System Prompt(可选,已宏替换后的内容) */
  presetSystemPrompt?: string;
  /**
   * 长期记忆摘要(可选,非空时作为 System 消息插入到 DialogueExamples 与 Conversation 之间)。
   * 调用方负责从 MemoryService.getInjectionContext 取得当前 Branch 的有效摘要文本。
   * v12: 若 memoryLayers 提供,此字段被忽略(优先使用分层注入)。
   */
  memorySummary?: string;
  /**
   * v12: 多层记忆注入参数(可选)。
   * 提供时按 Core/Chapter/Rolling/Legacy 分层注入,优先级高于 memorySummary。
   */
  memoryLayers?: MemoryLayersInjection;
  /** 是否启用 Post-History Instructions(默认 true)。
   *  Post-History Instructions 只有在对应提示词功能启用时才注入。
   *  当角色有 postHistoryInstructions 但此 flag 为 false 时不注入。 */
  enablePostHistoryInstructions?: boolean;
  /** 角色专属世界书的全局默认激活方式(可选,书级遗留 FollowGlobal 时兜底) */
  characterBookActivationMode?: LorebookActivationMode;
  /** 深度注入位置(0-8,默认 2)。仅在 OnDemand 模式下生效 */
  lorebookDepth?: number;
  /** v44: 记忆关键词检索命中的历史章节(可选开关,位置固定于对话前)。 */
  memoryKeywordHits?: MemoryKeywordHit[];
  /** 用户身份(可选,提供时注入到提示词) */
  persona?: Persona;
  /** 用户身份注入深度(仅 persona.position = AtDepth 时使用,默认 4) */
  personaDepth?: number;
}

/**
 * 记忆关键词检索命中条目(标题 + 内容),注入到 MemoryLegacy 之后、对话之前。
 */
export interface MemoryKeywordHit {
  readonly title: string;
  readonly detail: string;
}

/**
 * 世界书深度注入计划。
 * content 非空时表示有命中条目,按 depth 注入到对话尾部。
 */
interface LorebookDepthPlan {
  /** 深度注入内容(多条以 \n\n 连接),空表示无需深度注入 */
  readonly content: string;
  /** 深度值(0-8),0 表示全部消息之后 */
  readonly depth: number;
}

/** OnDemand 深度注入默认深度 */
const DEFAULT_LOREBOOK_DEPTH: number = 2;

/**
 * Prompt 构建结果。
 */
export interface PromptBuildResult {
  /** 构建后的请求消息列表 */
  messages: ChatMessage[];
  /** 匹配到的世界书条目 ID 列表(含全局 + 角色专属) */
  matchedLorebookEntryIds: string[];
}

/**
 * 提示词构建器。
 */
export class PromptBuilder {
  private readonly lorebookService: LorebookService;
  private readonly macroReplacer: MacroReplacer;

  constructor(lorebookService: LorebookService, macroReplacer: MacroReplacer) {
    this.lorebookService = lorebookService;
    this.macroReplacer = macroReplacer;
  }

  /**
   * 构建最终请求消息。
   *
   * 顺序:
   *   PromptPreset → BeforeCharacter → Character → AfterCharacter
   *   → DialogueExamples → Conversation → PostHistory
   *
   * 世界书内容作为 System 消息发送,不进入 ChatService 可见消息。
   * 不修改传入的 messages 数组。
   *
   * @param context 构建上下文
   * @returns 构建结果
   */
  build(context: PromptBuildContext): PromptBuildResult {
    const segments: PromptSegment[] = [];
    const matchedIds: string[] = [];
    const now: number = Date.now();

    // 1. Preset System Prompt(附加,不替换)
    if (context.presetSystemPrompt !== undefined &&
      context.presetSystemPrompt.trim().length > 0) {
      const presetSeg: PromptSegment = createPromptSegment(
        'preset-system',
        PromptSegmentPosition.PromptPreset,
        ChatRole.System,
        context.presetSystemPrompt,
        0,
        ChatMessageSource.PromptPresetSystem
      );
      segments.push(presetSeg);
    }

    // 2. 世界书(BeforeCharacter + AfterCharacter)
    // 全局 lorebook 与角色 characterBook 叠加
    // OnDemand 模式下的关键词命中条目由深度计划返回,在步骤 5 按深度注入
    let lorebookDepthContent: string = '';
    let lorebookDepthValue: number = 0;
    const lorebookDepthPlan: LorebookDepthPlan =
      this.collectLorebookSegments(context, segments, matchedIds);
    if (lorebookDepthPlan.content.length > 0) {
      lorebookDepthContent = lorebookDepthPlan.content;
      lorebookDepthValue = lorebookDepthPlan.depth;
    }

    // 3. Character System Prompt(支持 {{original}})
    if (context.character !== undefined && context.character !== null) {
      const character: Character = context.character;
      const systemContent: string = this.buildCharacterSystemWithOriginal(character);
      if (systemContent.length > 0) {
        const charSeg: PromptSegment = createPromptSegment(
          'character-system',
          PromptSegmentPosition.Character,
          ChatRole.System,
          systemContent,
          0,
          ChatMessageSource.CharacterPrompt
        );
        segments.push(charSeg);
      }
    }

    // 3.5 Persona 注入
    let personaAtDepthContent: string = '';
    let personaAtDepthValue: number = 0;
    if (context.persona !== undefined && context.persona !== null) {
      const persona: Persona = context.persona;
      if (persona.position !== PersonaPosition.Disabled) {
        const personaContent: string = this.buildPersonaContent(persona);
        if (personaContent.length > 0) {
          if (persona.position === PersonaPosition.BeforeCharacter) {
            const seg: PromptSegment = createPromptSegment(
              'persona-before',
              PromptSegmentPosition.PersonaBefore,
              ChatRole.System,
              personaContent,
              0,
              ChatMessageSource.PersonaBefore
            );
            segments.push(seg);
          } else if (persona.position === PersonaPosition.AfterCharacter) {
            const seg: PromptSegment = createPromptSegment(
              'persona-after',
              PromptSegmentPosition.PersonaAfter,
              ChatRole.System,
              personaContent,
              0,
              ChatMessageSource.PersonaAfter
            );
            segments.push(seg);
          } else if (persona.position === PersonaPosition.AtDepth) {
            // AtDepth 在步骤 5 的 Conversation 段中按深度插入
            personaAtDepthContent = personaContent;
            personaAtDepthValue = context.personaDepth !== undefined
              ? context.personaDepth : persona.depth;
          }
        }
      }
    }

    // 4. DialogueExamples(mes_example)
    if (context.character !== undefined && context.character !== null) {
      const mesExample: string = context.character.mesExample;
      if (mesExample.trim().length > 0) {
        const exampleSegments: PromptSegment[] = this.buildMesExampleSegments(mesExample);
        for (let i = 0; i < exampleSegments.length; i++) {
          segments.push(exampleSegments[i]);
        }
      }
    }

    // 4.5 长期记忆注入(v12 多层优先,回退单段)
    // v12: 若 memoryLayers 提供,按 Core/Chapter/Rolling/Legacy 分层注入
    // 否则回退到 memorySummary 单段注入(旧路径兼容)
    if (context.memoryLayers !== undefined) {
      this.collectMemoryLayerSegments(context.memoryLayers, segments);
    } else if (context.memorySummary !== undefined &&
      context.memorySummary.trim().length > 0) {
      const memorySeg: PromptSegment = createPromptSegment(
        'memory-summary',
        PromptSegmentPosition.MemorySummary,
        ChatRole.System,
        context.memorySummary,
        0,
        ChatMessageSource.MemorySummary
      );
      segments.push(memorySeg);
    }

    // 4.6 记忆关键词检索命中(可选开关,位置固定于对话前;内容随命中变化,仅开启时接受缓存代价)
    if (context.memoryKeywordHits !== undefined && context.memoryKeywordHits.length > 0) {
      const parts: string[] = [];
      for (let i = 0; i < context.memoryKeywordHits.length; i++) {
        const hit: MemoryKeywordHit = context.memoryKeywordHits[i];
        parts.push('【' + hit.title + '】' + '\n' + hit.detail);
      }
      const kwSeg: PromptSegment = createPromptSegment(
        'memory-keyword',
        PromptSegmentPosition.MemoryKeyword,
        ChatRole.System,
        parts.join('\n\n'),
        0,
        ChatMessageSource.MemorySummary
      );
      segments.push(kwSeg);
    }

    // 5. Conversation:保留输入中的所有消息(包括合法 System 消息)
    // Character System Prompt 已由 Step 3 动态生成,不再从输入中取
    // 世界书 System 消息已由 Step 2 动态生成
    // firstMessage 识别:输入 messages 中第一条 Assistant 消息视为 firstMessage
    // Persona AtDepth:按深度在 Conversation 消息中插入 System 消息
    let firstAssistantSeen: boolean = false;
    let injectedPersonaAtDepth: boolean = false;
    let injectedLorebookDepth: boolean = false;
    // 世界书深度注入点:在倒数第 depth 条消息之前(按全部消息从底部计数,depth=0 表示全部消息之后)
    const lorebookDepthInsertIndex: number = Math.max(0, context.messages.length - lorebookDepthValue);
    // 计算消息中 Assistant 消息的索引(从后往前数深度)
    // depth=0 表示最底部(最新消息),depth=4 表示倒数第5条 Assistant 消息之前
    const assistantMsgCount: number = this.countAssistantMessages(context.messages);
    const injectAfterAssistantIndex: number = assistantMsgCount - personaAtDepthValue;
    let assistantSeenSoFar: number = 0;
    for (let i = 0; i < context.messages.length; i++) {
      const msg: ChatMessage = context.messages[i];
      // 世界书 OnDemand 深度注入点:在倒数第 lorebookDepth 条消息之前
      if (!injectedLorebookDepth && lorebookDepthContent.length > 0 && i === lorebookDepthInsertIndex) {
        const lorebookDepthSeg: PromptSegment = createPromptSegment(
          'lorebook-depth',
          PromptSegmentPosition.Conversation,
          ChatRole.System,
          lorebookDepthContent,
          0,
          ChatMessageSource.LorebookDepth
        );
        segments.push(lorebookDepthSeg);
        injectedLorebookDepth = true;
      }
      // Persona AtDepth 注入点:在指定深度的 Assistant 消息之后
      if (!injectedPersonaAtDepth && personaAtDepthContent.length > 0
        && msg.role === ChatRole.Assistant) {
        assistantSeenSoFar++;
        if (assistantSeenSoFar >= injectAfterAssistantIndex && injectAfterAssistantIndex > 0) {
          // 先注入 Persona
          const depthSeg: PromptSegment = createPromptSegment(
            'persona-at-depth',
            PromptSegmentPosition.Conversation,
            ChatRole.System,
            personaAtDepthContent,
            0,
            ChatMessageSource.PersonaBefore
          );
          segments.push(depthSeg);
          injectedPersonaAtDepth = true;
        }
      }
      let source: ChatMessageSource = ChatMessageSource.Conversation;
      if (msg.senderType === 'narrator') {
        source = ChatMessageSource.NarratorInstruction;
      } else if (msg.role === ChatRole.System) {
        source = ChatMessageSource.ExternalSystem;
      } else if (msg.role === ChatRole.Assistant && !firstAssistantSeen) {
        source = ChatMessageSource.CharacterFirstMessage;
        firstAssistantSeen = true;
      }
      const convSeg: PromptSegment = createPromptSegment(
        msg.id,
        PromptSegmentPosition.Conversation,
        msg.role,
        msg.content,
        0,
        source
      );
      segments.push(convSeg);
    }
    // depth=0(或深度超过消息数)时,世界书深度注入放在全部消息之后
    if (!injectedLorebookDepth && lorebookDepthContent.length > 0) {
      const lorebookDepthSeg: PromptSegment = createPromptSegment(
        'lorebook-depth',
        PromptSegmentPosition.Conversation,
        ChatRole.System,
        lorebookDepthContent,
        0,
        ChatMessageSource.LorebookDepth
      );
      segments.push(lorebookDepthSeg);
    }

    // 6. Post-History Instructions(放在聊天历史之后)
    // 只有在功能启用时才注入,不作为可见聊天消息保存
    if (context.character !== undefined && context.character !== null) {
      const character: Character = context.character;
      const enabled: boolean = context.enablePostHistoryInstructions !== undefined
        ? context.enablePostHistoryInstructions : true;
      if (enabled && character.postHistoryInstructions.trim().length > 0) {
        const postContent: string = this.applyOriginalMacro(
          character.postHistoryInstructions, ''
        );
        if (postContent.trim().length > 0) {
          const postSeg: PromptSegment = createPromptSegment(
            'character-post-history',
            PromptSegmentPosition.PostHistory,
            ChatRole.System,
            postContent,
            0,
            ChatMessageSource.CharacterPostHistory
          );
          segments.push(postSeg);
        }
      }
    }

    // 排序:position → priority
    const sorted: PromptSegment[] = sortSegments(segments);

    // 转换为 ChatMessage[](如提供 macroContext,对每条消息内容执行宏替换)
    const macroCtx: MacroContext | undefined = context.macroContext;
    const resultMessages: ChatMessage[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const seg: PromptSegment = sorted[i];
      let content: string = seg.content;
      if (macroCtx !== undefined) {
        content = this.macroReplacer.replace(content, macroCtx);
      }
      const msg: ChatMessage = createChatMessage(
        seg.id,
        seg.role,
        content,
        now
      );
      // 携带 source 标签(内部辅助标记,不会写入网络请求 JSON)
      resultMessages.push({
        id: msg.id,
        role: msg.role,
        content: msg.content,
        createdAt: msg.createdAt,
        source: seg.source
      });
    }

    const result: PromptBuildResult = {
      messages: resultMessages,
      matchedLorebookEntryIds: matchedIds
    };
    return result;
  }

  /**
   * v12: 收集多层记忆 segments(Core/Chapter/Rolling/Legacy)。
   * - Core:全量注入,作为 System 消息插入 MemoryCore 位置
   * - Chapter:按时间正序(早→晚)注入,每章一条 System 消息
   * - Rolling:最近 1 条,作为 System 消息插入 MemoryRolling 位置
   * - Legacy:旧数据迁移摘要,作为 System 消息插入 MemoryLegacy 位置
   * - 空内容(或纯空白)的 memory 跳过
   * - 同位置内 priority 按时间顺序(早的 priority 更高,保持正序)
   */
  private collectMemoryLayerSegments(
    layers: MemoryLayersInjection,
    segments: PromptSegment[]
  ): void {
    // Core:全量注入(高优先级)
    for (let i = 0; i < layers.core.length; i++) {
      const m: ChatMemory = layers.core[i];
      const content: string = m.summary.trim();
      if (content.length === 0) {
        continue;
      }
      const seg: PromptSegment = createPromptSegment(
        'memory-core-' + m.id,
        PromptSegmentPosition.MemoryCore,
        ChatRole.System,
        '【核心长期记忆】\n' + content,
        100 - i, // Core 之间按顺序优先级递减
        ChatMessageSource.MemoryCore
      );
      segments.push(seg);
    }

    // Chapter:按时间正序注入(传入时已按 endPosition DESC,需反转为 ASC)
    const sortedChapter: ChatMemory[] = layers.chapter.slice().sort(
      (a: ChatMemory, b: ChatMemory): number => a.endPosition - b.endPosition
    );
    for (let i = 0; i < sortedChapter.length; i++) {
      const m: ChatMemory = sortedChapter[i];
      const content: string = m.summary.trim();
      if (content.length === 0) {
        continue;
      }
      const title: string = m.title.length > 0 ? m.title : ('章节 ' + (i + 1));
      const seg: PromptSegment = createPromptSegment(
        'memory-chapter-' + m.id,
        PromptSegmentPosition.MemoryChapter,
        ChatRole.System,
        '【' + title + '】\n' + content,
        sortedChapter.length - i, // 早期章节 priority 略高,保持正序展示
        ChatMessageSource.MemoryChapter
      );
      segments.push(seg);
    }

    // Rolling:最近 1 条
    for (let i = 0; i < layers.rolling.length; i++) {
      const m: ChatMemory = layers.rolling[i];
      const content: string = m.summary.trim();
      if (content.length === 0) {
        continue;
      }
      const seg: PromptSegment = createPromptSegment(
        'memory-rolling-' + m.id,
        PromptSegmentPosition.MemoryRolling,
        ChatRole.System,
        '【近期记忆】\n' + content,
        0,
        ChatMessageSource.MemoryRolling
      );
      segments.push(seg);
    }

    // Legacy:旧数据迁移摘要
    for (let i = 0; i < layers.legacy.length; i++) {
      const m: ChatMemory = layers.legacy[i];
      const content: string = m.summary.trim();
      if (content.length === 0) {
        continue;
      }
      const seg: PromptSegment = createPromptSegment(
        'memory-legacy-' + m.id,
        PromptSegmentPosition.MemoryLegacy,
        ChatRole.System,
        '【早期记忆】\n' + content,
        0,
        ChatMessageSource.MemoryLegacy
      );
      segments.push(seg);
    }
  }

  /**
   * 收集角色绑定世界书的 segments。
   * - 书需要 enabled 才参与匹配
   * - 按书级激活方式处理:
   *   - FullInject:全量 enabled 条目注入头部(全部发给模型,缓存最优)
   *   - OnDemand:constant 注入头部 + 关键词命中条目累积到深度计划(SillyTavern 式按需)
   *   - 遗留 FollowGlobal:用全局默认解析,未解析时回退现状行为(关键词匹配注入头部)
   * - 按 position 分到 BeforeCharacter / AfterCharacter
   * - priority 用于同位置内排序
   * @returns 深度注入计划(OnDemand 命中条目),无命中时 content 为空
   */
  private collectLorebookSegments(
    context: PromptBuildContext,
    segments: PromptSegment[],
    matchedIds: string[]
  ): LorebookDepthPlan {
    const depthParts: string[] = [];
    if (context.characterBook !== undefined && context.characterBook !== null
      && context.characterBook.enabled) {
      const charMode: LorebookActivationMode | undefined = this.resolveBookMode(
        context.characterBook, context.characterBookActivationMode
      );
      this.collectBookEntries(context.characterBook, charMode, context, segments, matchedIds, depthParts);
    }
    if (depthParts.length === 0) {
      const empty: LorebookDepthPlan = { content: '', depth: 0 };
      return empty;
    }
    const depthValue: number = context.lorebookDepth !== undefined
      ? context.lorebookDepth : DEFAULT_LOREBOOK_DEPTH;
    const plan: LorebookDepthPlan = {
      content: depthParts.join('\n\n'),
      depth: depthValue
    };
    return plan;
  }

  /**
   * 解析一本书的有效激活方式。
   * 书级 FollowGlobal 时用全局默认;全局默认 undefined 时返回 undefined(回退现状行为)。
   */
  private resolveBookMode(
    book: Lorebook,
    globalDefault: LorebookActivationMode | undefined
  ): LorebookActivationMode | undefined {
    if (book.activationMode !== LorebookActivationMode.FollowGlobal) {
      return book.activationMode;
    }
    return globalDefault;
  }

  /**
   * 按激活方式收集一本书的注入。
   * mode undefined 时回退现状行为(matchEntriesForLorebook 注入头部)。
   */
  private collectBookEntries(
    book: Lorebook,
    mode: LorebookActivationMode | undefined,
    context: PromptBuildContext,
    segments: PromptSegment[],
    matchedIds: string[],
    depthParts: string[]
  ): void {
    if (mode === undefined) {
      this.pushHeadSegments(this.lorebookService.matchEntriesForLorebook(book, context.messages),
        segments, matchedIds);
      return;
    }
    if (mode === LorebookActivationMode.FullInject) {
      this.pushHeadSegments(this.lorebookService.collectAllEntries(book), segments, matchedIds);
      return;
    }
    // OnDemand:constant 注入头部,命中条目累积到深度计划
    this.pushHeadSegments(this.lorebookService.collectConstantEntries(book), segments, matchedIds);
    const matched: LorebookEntry[] = this.lorebookService.matchKeywordEntries(book, context.messages);
    for (let i = 0; i < matched.length; i++) {
      matchedIds.push(matched[i].id);
      depthParts.push(matched[i].content);
    }
  }

  /**
   * 把条目按 position 分发为头部 segments(BeforeCharacter / AfterCharacter)。
   */
  private pushHeadSegments(
    entries: LorebookEntry[],
    segments: PromptSegment[],
    matchedIds: string[]
  ): void {
    for (let i = 0; i < entries.length; i++) {
      const entry: LorebookEntry = entries[i];
      matchedIds.push(entry.id);
      const isBefore: boolean = entry.position === LorebookPosition.BeforeCharacter;
      const position: PromptSegmentPosition = isBefore
        ? PromptSegmentPosition.BeforeCharacter
        : PromptSegmentPosition.AfterCharacter;
      const source: ChatMessageSource = isBefore
        ? ChatMessageSource.LorebookBefore
        : ChatMessageSource.LorebookAfter;
      const seg: PromptSegment = createPromptSegment(
        'lorebook-' + entry.id,
        position,
        ChatRole.System,
        entry.content,
        entry.priority,
        source
      );
      segments.push(seg);
    }
  }

  /**
   * 构建角色 System 内容。
   * - character.systemPrompt 为空时,返回默认组合(name/description/personality/scenario)
   * - character.systemPrompt 非空时,处理 {{original}} 宏
   *   {{original}} 替换为默认组合内容(由 buildDefaultCharacterSystemContent 生成)
   *   若不包含 {{original}},原样使用 systemPrompt
   */
  private buildCharacterSystemWithOriginal(character: Character): string {
    if (character.systemPrompt.trim().length === 0) {
      return buildCharacterSystemContent(character);
    }
    // systemPrompt 非空,处理 {{original}}
    const defaultContent: string = buildDefaultCharacterSystemContent(character);
    return this.applyOriginalMacro(character.systemPrompt, defaultContent);
  }

  /**
   * 构建 Persona 注入内容。
   * 格式: persona.name + '\n' + persona.description
   * 如果 description 为空,仅使用 name。
   */
  private buildPersonaContent(persona: Persona): string {
    if (persona.description.trim().length > 0) {
      return persona.name + '\n' + persona.description.trim();
    }
    return persona.name;
  }

  /**
   * 统计消息列表中 Assistant 消息的数量。
   * 用于计算 AtDepth 注入位置。
   */
  private countAssistantMessages(messages: ChatMessage[]): number {
    let count: number = 0;
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role === ChatRole.Assistant) {
        count++;
      }
    }
    return count;
  }

  /**
   * 替换文本中的 {{original}} 宏为 originalContent。
   * 若 originalContent 为空字符串,{{original}} 被替换为空字符串。
   */
  private applyOriginalMacro(content: string, originalContent: string): string {
    if (content.length === 0) {
      return '';
    }
    // 简单字符串替换(大小写不敏感)
    // 使用正则全局替换,\b 边界防止误匹配 {{original_something}}
    const pattern: RegExp = /\{\{original\}\}/gi;
    return content.replace(pattern, originalContent);
  }

  /**
   * 构建对话示例 segments。
   *
   * SillyTavern mes_example 规范:
   * - 用 <START> 分隔多组对话示例
   * - 每段内可以包含 {{char}}: 或 <char>: 标记角色说话
   * - {{user}}: 或 <user>: 标记用户说话
   *
   * 简化方案:
   * - 按 <START> 分割为多段
   * - 每段 trim 后非空时,作为独立的 System 消息插入 DialogueExamples 位置
   * - 不解析为 User/Assistant 对话,保持原始文本结构
   *   (这样模型可以理解示例的对话风格,同时实现简单且符合 V2 规范)
   *
   * @param mesExample 角色的 mes_example 字段
   * @returns segments 数组(可能为空)
   */
  private buildMesExampleSegments(mesExample: string): PromptSegment[] {
    const segments: PromptSegment[] = [];
    if (mesExample.trim().length === 0) {
      return segments;
    }
    // 按 <START> 分割(不区分大小写)
    const parts: string[] = mesExample.split(new RegExp(EXAMPLE_SEPARATOR, 'i'));
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i].trim();
      if (part.length === 0) {
        continue;
      }
      const seg: PromptSegment = createPromptSegment(
        'character-mes-example-' + String(i),
        PromptSegmentPosition.DialogueExamples,
        ChatRole.System,
        part,
        -i,  // 越靠前的示例优先级越高(同位置内降序),保持原序
        ChatMessageSource.CharacterMesExample
      );
      segments.push(seg);
    }
    return segments;
  }

  /**
   * 构建用于宏替换的 MacroContext。
   * 由 ChatService 调用,补充所有角色字段供 {{description}} {{original}} 等宏使用。
   */
  buildMacroContext(
    character: Character | null,
    userName: string,
    messages: ChatMessage[]
  ): MacroContext {
    const characterName: string = resolveCharacterDisplayName(character);
    const builder: MacroContextBuilder = new MacroContextBuilder(characterName, userName);
    if (character !== null) {
      builder
        .withDescription(character.description)
        .withPersonality(character.personality)
        .withScenario(character.scenario)
        .withMesExample(character.mesExample);
      // {{original}} 在角色 systemPrompt / postHistoryInstructions 中引用默认组合内容
      const originalContent: string = buildDefaultCharacterSystemContent(character);
      builder.withOriginalContent(originalContent);
    }
    // {{lastMessage}}:取最后一条消息内容(若有)
    if (messages.length > 0) {
      const lastMsg: ChatMessage = messages[messages.length - 1];
      if (lastMsg.content.length > 0) {
        builder.withLastMessage(lastMsg.content);
      }
    }
    return builder.build();
  }
}
