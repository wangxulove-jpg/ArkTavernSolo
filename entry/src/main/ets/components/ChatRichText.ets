/**
 * ChatRichText 聊天富文本渲染组件
 *
 * 职责:
 * - 接收原始文本和发送者信息,解析为富文本片段并渲染
 * - 支持 Markdown 子集(加粗/斜体/删除线/代码/链接/引用/列表)
 * - 支持角色对白差异化配色
 * - 支持流式渲染(流式期间以打字机逐字揭示 + 节流解析)
 * - 支持长按复制原始文本
 * - 支持字体大小/行间距缩放
 *
 * 不负责:
 * - 消息气泡背景/布局(由调用方提供)
 * - 头像/名称显示(由调用方提供)
 * - 设置 UI(由 AppSettingsPage 提供)
 *
 * 使用方式:
 *   ChatRichText({
 *     content: message.content,
 *     senderType: message.senderType,
 *     senderCharacterId: message.senderCharacterId,
 *     isStreaming: false,
 *     settings: chatTextStyleSettings,
 *     selectable: true
 *   })
 */

import { ChatTextSegment, parseChatText, ChatTextParserOptions } from '../parser/ChatTextParser';
import { getCharacterColor } from '../utils/ChatPalette';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { ChatMarkdownColorTheme } from '../utils/ChatTextColorTheme';

/** 发送者类型 */
export type ChatSenderType = 'user' | 'assistant' | 'character' | 'narrator' | 'system';

/** 缓存条目 */
interface CacheEntry {
  readonly segments: ChatTextSegment[];
  readonly contentHash: number;
}

/** 简单字符串哈希(FNV-1a 32位) */
function hashString(str: string): number {
  let hash: number = 2166136261;
  for (let i = 0; i < str.length; i++) {
    hash ^= str.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

@Component
export struct ChatRichText {
  /** 原始文本内容(@Watch 监听变化,触发重新解析) */
  @Prop @Watch('onContentChange') content: string = '';
  /** 发送者类型 */
  @Prop senderType: ChatSenderType = 'assistant';
  /** 发送者角色 ID(用于角色独立颜色,@Watch 触发重新应用颜色) */
  @Prop @Watch('onSenderChange') senderCharacterId: string = '';
  /** 是否流式渲染(节流刷新,@Watch 在生成完成时立即重新解析) */
  @Prop @Watch('onStreamingChange') isStreaming: boolean = false;
  /** 文本样式设置(@Watch 触发重新解析) */
  @Prop @Watch('onSettingsChange') settings: ChatTextStyle | null = null;
  /**
   * 字体颜色主题(null 表示 AUTO 模式,使用默认资源颜色)。
   * 非 null 时覆盖 getSegmentColor 的颜色查询,不改变解析行为、节点结构、
   * 字体粗细、链接行为或换行逻辑。
   * @Watch 触发重新解析,确保缓存 key 包含主题指纹。
   */
  @Prop @Watch('onThemeChange') colorTheme: ChatMarkdownColorTheme | null = null;
  /** 是否可选择(长按复制) */
  @Prop selectable: boolean = true;

  /** 当前解析的片段(状态) */
  @State private segments: ChatTextSegment[] = [];

  // ===== 流式打字机状态 =====
  /** 是否处于打字机揭示中(流式或排空期间为 true,完整显示为 false) */
  private typing: boolean = false;
  /** 打字机揭示定时器 ID(-1 表示无 pending) */
  private revealTimerId: number = -1;
  /** 已揭示的字符数(流式期间随打字机增长) */
  private revealedLength: number = 0;
  /** 当前揭示的文本(流式期间为 content 的前缀,非流式等于 content) */
  private displayedContent: string = '';
  /** 打字机 tick 间隔(ms) */
  private static readonly TYPEWRITER_INTERVAL_MS: number = 30;
  /** 每次 tick 揭示的字符数(约 100 字/秒) */
  private static readonly TYPEWRITER_CHARS_PER_TICK: number = 3;

  /** 解析缓存(LRU,key = content hash + 设置指纹 + senderCharacterId) */
  private static cache: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  /** 缓存上限(LRU,达到后淘汰最旧条目) */
  private static readonly CACHE_MAX_SIZE: number = 200;

  aboutToAppear(): void {
    if (this.isStreaming) {
      // 流式期间首次挂载:从 0 开始打字机揭示,避免一次性显示已缓冲的整段内容
      this.typing = true;
      this.revealedLength = 0;
      this.displayedContent = '';
      this.doParse();
      this.ensureTypewriterRunning();
    } else {
      // 非流式(历史消息/已完成):直接显示完整内容
      this.typing = false;
      this.displayedContent = this.content;
      this.revealedLength = this.content.length;
      this.doParse();
    }
  }

  aboutToDisappear(): void {
    this.clearTypewriter();
  }

  /**
   * @Watch 回调:content 变化时重新解析。
   * 打字机揭示期间继续揭示;完整显示状态则直接更新为完整内容。
   */
  private onContentChange(): void {
    if (this.typing) {
      this.ensureTypewriterRunning();
    } else {
      this.clearTypewriter();
      this.displayedContent = this.content;
      this.revealedLength = this.content.length;
      this.doParse();
    }
  }

  /**
   * @Watch 回调:settings 变化时立即重新解析。
   */
  private onSettingsChange(): void {
    this.doParse();
  }

  /**
   * @Watch 回调:colorTheme 变化时立即重新解析。
   * 主题切换(AUTO ↔ LIGHT/DARK/CUSTOM)需要重新应用颜色。
   * 解析逻辑本身不变,但缓存 key 包含主题指纹,会生成新的片段列表。
   */
  private onThemeChange(): void {
    this.doParse();
  }

  /**
   * @Watch 回调:senderCharacterId 变化时立即重新解析(应用角色颜色)。
   */
  private onSenderChange(): void {
    this.doParse();
  }

  /**
   * @Watch 回调:isStreaming 变化时重新解析。
   * 生成完成(isStreaming: true → false)时保持 typing 状态,让打字机继续排空剩余内容,
   * 避免流式期间积压的文本在完成瞬间一次性跳出,保持逐字打字效果。
   * 开始流式(false → true)时重置揭示进度并启动打字机。
   */
  private onStreamingChange(): void {
    if (!this.isStreaming) {
      // 保持 typing = true:若打字机仍在排空则继续;若已揭示完,typewriterTick 会立即结束并显示完整内容
      this.ensureTypewriterRunning();
    } else {
      this.typing = true;
      this.clearTypewriter();
      this.revealedLength = 0;
      this.displayedContent = '';
      this.doParse();
      this.ensureTypewriterRunning();
    }
  }

  // ===== 流式打字机实现 =====

  /**
   * 清除打字机定时器。
   */
  private clearTypewriter(): void {
    if (this.revealTimerId !== -1) {
      clearTimeout(this.revealTimerId);
      this.revealTimerId = -1;
    }
  }

  /**
   * 确保打字机揭示定时器在运行(幂等)。
   */
  private ensureTypewriterRunning(): void {
    if (this.revealTimerId !== -1) {
      return;
    }
    this.typewriterTick();
  }

  /**
   * 打字机单次 tick:揭示一段字符并重新解析。
   * - 已揭示到当前完整内容:若流式已结束则结束打字机状态(typing=false),否则等待下一次 content 增长
   * - 尚未揭示完:调度下一次 tick
   */
  private typewriterTick(): void {
    this.revealTimerId = -1;
    const target: number = this.content.length;
    if (this.revealedLength >= target) {
      this.displayedContent = this.content;
      if (!this.isStreaming) {
        this.typing = false;
      }
      this.doParse();
      return;
    }
    this.revealedLength = Math.min(
      this.revealedLength + ChatRichText.TYPEWRITER_CHARS_PER_TICK,
      target
    );
    this.displayedContent = this.content.substring(0, this.revealedLength);
    this.doParse();
    if (this.revealedLength < target) {
      this.revealTimerId = setTimeout((): void => {
        this.typewriterTick();
      }, ChatRichText.TYPEWRITER_INTERVAL_MS);
    } else if (!this.isStreaming) {
      // 揭示到完整内容且流式已结束,结束打字机状态
      this.typing = false;
    }
  }

  /**
   * 执行解析。
   *
   * 解析当前已揭示文本(displayedContent):
   * - 流式/排空期间为 content 的前缀(随打字机逐字增长)
   * - 完整内容时恒等于 content
   * 未闭合 Markdown 由 ChatTextParser 安全降级为普通文本。
   *
   * 缓存策略:
   * - 揭示未完成(revealedLength < content.length):跳过缓存,直接解析
   * - 完整内容:使用 LRU 缓存复用,避免历史消息重复解析
   */
  private doParse(): void {
    const text: string = this.displayedContent;
    if (text.length === 0) {
      this.segments = [];
      return;
    }

    const settings: ChatTextStyle = this.settings !== null ? this.settings : {
      enableMarkdown: true,
      enableDialogue: true,
      enableCharacterColor: true,
      fontSize: 16,
      lineHeight: 1.5,
      quoteStyle: 'line',
      codeStyle: 'bg'
    };

    const options: ChatTextParserOptions = {
      enableMarkdown: settings.enableMarkdown,
      enableDialogue: settings.enableDialogue
    };

    // 打字机揭示中(流式或排空):跳过缓存,直接解析当前已揭示文本
    if (this.typing) {
      this.segments = parseChatText(text, options);
      return;
    }

    // 完整内容:使用 LRU 缓存复用
    const contentHash: number = hashString(text);
    const cacheKey: string = this.buildCacheKey(contentHash, settings);
    const cached: CacheEntry | undefined = ChatRichText.cache.get(cacheKey);
    if (cached !== undefined && cached.contentHash === contentHash) {
      // LRU:命中时移到末尾(Map 保持插入顺序)
      ChatRichText.cache.delete(cacheKey);
      ChatRichText.cache.set(cacheKey, cached);
      this.segments = cached.segments;
      return;
    }

    // 解析并写入缓存
    const parsed: ChatTextSegment[] = parseChatText(text, options);
    this.evictCacheIfNeeded();
    ChatRichText.cache.set(cacheKey, {
      segments: parsed,
      contentHash: contentHash
    });

    this.segments = parsed;
  }

  /**
   * 构建缓存 key(包含 content hash + 设置指纹 + senderCharacterId + 主题指纹)。
   * 任何影响渲染的设置变化都会导致 key 变化,确保缓存正确隔离。
   * 主题指纹参与 key,避免 AUTO/LIGHT/DARK/CUSTOM 切换后命中旧缓存。
   */
  private buildCacheKey(contentHash: number, settings: ChatTextStyle): string {
    return contentHash.toString() + '_'
      + this.senderCharacterId + '_'
      + (settings.enableMarkdown ? '1' : '0') + '_'
      + (settings.enableDialogue ? '1' : '0') + '_'
      + settings.fontSize.toString() + '_'
      + settings.lineHeight.toString() + '_'
      + settings.quoteStyle + '_'
      + settings.codeStyle + '_'
      + this.buildThemeFingerprint();
  }

  /**
   * 构建颜色主题指纹(参与缓存 key)。
   * AUTO 模式(null)返回 'auto',其他模式返回各颜色字段(已为大写 #RRGGBB)。
   */
  private buildThemeFingerprint(): string {
    const t: ChatMarkdownColorTheme | null = this.colorTheme;
    if (t === null) {
      return 'auto';
    }
    return t.bodyColor + '|' + t.emphasisColor + '|' + t.dialogueColor + '|'
      + t.actionColor + '|' + t.codeColor + '|' + t.linkColor + '|'
      + t.quoteColor + '|' + t.userColor;
  }

  /**
   * LRU 淘汰:达到上限时删除最旧条目(Map 的第一个 key)。
   */
  private evictCacheIfNeeded(): void {
    while (ChatRichText.cache.size >= ChatRichText.CACHE_MAX_SIZE) {
      // Map 迭代顺序 = 插入顺序,第一个即最旧
      const oldestKey: string | undefined = ChatRichText.cache.keys().next().value;
      if (oldestKey === undefined) {
        break;
      }
      ChatRichText.cache.delete(oldestKey);
    }
  }

  /**
   * 获取片段对应的字体颜色。
   *
   * 主题优先级:
   * 1. colorTheme === null(AUTO 模式):使用默认资源颜色 $r('app.color.*')(保持原行为)
   * 2. colorTheme !== null(LIGHT/DARK/CUSTOM):按 colorRole 映射到主题字段
   *
   * 角色独立颜色(对白 + character senderType)在两种模式下都保留,
   * 因为它由 ChatPalette 按角色 ID 解析,不属于 Markdown 语义颜色。
   *
   * 不改变解析行为、节点结构、字体粗细、链接行为或换行逻辑。
   */
  private getSegmentColor(seg: ChatTextSegment): ResourceColor {
    // 角色独立颜色优先(对白)
    if (seg.dialogue && this.senderType === 'character' && this.settings !== null && this.settings.enableCharacterColor && this.senderCharacterId.length > 0) {
      return getCharacterColor(this.senderCharacterId);
    }

    // AUTO 模式:使用默认资源颜色(保持原行为)
    if (this.colorTheme === null) {
      switch (seg.colorRole) {
        case 'emphasis':
          return $r('app.color.chat_text_emphasis');
        case 'secondary':
          return $r('app.color.chat_text_secondary');
        case 'dialogue':
          return $r('app.color.chat_text_dialogue');
        case 'narrator':
          return $r('app.color.chat_text_narrator');
        case 'action':
          return $r('app.color.chat_text_action');
        case 'code':
          return $r('app.color.chat_text_code');
        case 'link':
          return $r('app.color.chat_text_link');
        case 'quote':
          return $r('app.color.chat_text_quote');
        case 'system':
          return $r('app.color.chat_text_system');
        case 'character':
          return $r('app.color.chat_text_dialogue');
        default:
          // 根据 senderType 选择默认色
          if (this.senderType === 'user') {
            return $r('app.color.chat_user_text');
          } else if (this.senderType === 'system') {
            return $r('app.color.chat_text_system');
          }
          return $r('app.color.chat_text_primary');
      }
    }

    // LIGHT / DARK / CUSTOM 模式:按 colorRole 映射到语义化主题字段
    const theme: ChatMarkdownColorTheme = this.colorTheme;
    switch (seg.colorRole) {
      case 'emphasis':
      case 'secondary':
        // 加粗/斜体/删除线归入强调色
        return theme.emphasisColor;
      case 'dialogue':
      case 'character':
        // 对白/角色对白使用独立对白色
        return theme.dialogueColor;
      case 'narrator':
      case 'action':
        // 动作/旁白使用独立动作色
        return theme.actionColor;
      case 'code':
        return theme.codeColor;
      case 'link':
        return theme.linkColor;
      case 'quote':
        return theme.quoteColor;
      case 'system':
        return theme.bodyColor;
      default:
        // 根据 senderType 选择默认色
        if (this.senderType === 'user') {
          return theme.userColor;
        }
        return theme.bodyColor;
    }
  }

  build() {
    if (this.segments.length === 0) {
      // 空内容占位
      Text('')
        .fontSize(this.settings !== null ? this.settings.fontSize : 16)
        .height(0)
    } else {
      // 使用 Text + ForEach Span 的方式渲染富文本
      Text() {
        ForEach(this.segments, (seg: ChatTextSegment, index: number) => {
          Span(seg.text)
            .fontColor(this.getSegmentColor(seg))
            .fontSize(this.settings !== null ? this.settings.fontSize : 16)
            .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
            .decoration({
              type: seg.strike ? TextDecorationType.LineThrough : TextDecorationType.None,
              color: this.getSegmentColor(seg)
            })
        }, (seg: ChatTextSegment, index: number) => index.toString() + '_' + seg.text.length.toString())
      }
      .lineHeight((this.settings !== null ? this.settings.fontSize : 16) * (this.settings !== null ? this.settings.lineHeight : 1.5))
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
    }
  }
}
