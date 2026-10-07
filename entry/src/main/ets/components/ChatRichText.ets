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

import { ChatTextSegment, parseChatChunks, ChatRenderChunk, ChatTextParserOptions, TableChatRenderChunk, TableChunkRow, ImageChatRenderChunk } from '../parser/ChatTextParser';
import { getCharacterColor } from '../utils/ChatPalette';
import { ChatTextStyle, DEFAULT_CHAT_TEXT_STYLE } from '../utils/ChatTextStyleSettings';
import { CHAT_FONT_SYSTEM } from '../utils/ChatFontRegistry';
import { ChatMarkdownColorTheme, ChatSymbolColorRule } from '../utils/ChatTextColorTheme';
import { ChatCollapsibleBlock } from './ChatCollapsibleBlock';
import { ChatBranchBlock } from './ChatBranchBlock';
import { ChatMessageImage } from './ChatMessageImage';
import { normalizeImageName } from '../models/LocalImage';
import { LocalImageResolution } from '../utils/LocalImageResolution';

/** 发送者类型 */
export type ChatSenderType = 'user' | 'assistant' | 'character' | 'narrator' | 'system';

/** 缓存条目 */
interface CacheEntry {
  readonly chunks: ChatRenderChunk[];
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
  /**
   * 自定义符号配色规则(所有配色模式下都生效)。
   * 命中片段按规则颜色渲染,优先级高于语义色;
   * @Watch 触发重新解析,确保缓存 key 包含规则指纹。
   */
  @Prop @Watch('onSymbolRulesChange') symbolRules: ChatSymbolColorRule[] = [];
  /**
   * 本地图片/视频库解析映射(归一化名字 → { file URI, 媒体类型 })。
   * 由 ChatPage 按当前角色加载后逐层透传;组件不碰服务/数据库(架构红线)。
   *
   * @Watch 只重跑「名字 → URI」解析映射,不重新解析文本(解析产物不含库信息)。
   * 性能提示:@Prop 对对象做深拷贝(消息数 × 表项数)。图库规模小时无感;
   * 若单库超过约 300 张或出现卡顿,应改成「@Prop version + 宿主回调解析」。
   */
  @Prop @Watch('onLocalImagesChange') localImages: Record<string, LocalImageResolution> = {};
  /** 是否可选择(长按复制) */
  @Prop selectable: boolean = true;
  /**
   * 是否把「前端界面 HTML 大块」折叠成一行(默认 true,契约 v3 卡片开场白的整页 HTML)。
   * 折叠块内部嵌套渲染必须传 false,否则源码会被再次折叠(套娃)。
   */
  @Prop foldFrontendHtml: boolean = true;
  /** 交互动作回调(分支选项点击时触发,由上层注入"把选项作为消息发送给 AI") */
  onInteractiveAction?: (text: string) => void;

  /** 当前解析的渲染分块(状态) */
  @State private chunks: ChatRenderChunk[] = [];
  /**
   * 未经本地图片解析的原始分块(文本解析产物)。
   * 解析产物与图片库无关(只含 kind + name),故图片库变化时只需重跑解析映射,
   * 不必重新解析文本 —— 见 onLocalImagesChange。
   */
  private rawChunks: ChatRenderChunk[] = [];

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
   * @Watch 回调:自定义符号规则变化时立即重新解析(应用新规则颜色)。
   */
  private onSymbolRulesChange(): void {
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
      this.chunks = [];
      return;
    }

    const settings: ChatTextStyle = this.settings !== null ? this.settings : {
      enableMarkdown: true,
      enableDialogue: true,
      enableCharacterColor: true,
      fontSize: 16,
      lineHeight: 1.5,
      fontFamily: CHAT_FONT_SYSTEM,
      quoteStyle: 'line',
      codeStyle: 'bg',
      imageWidthRatio: DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio,
      mediaAutoPlay: DEFAULT_CHAT_TEXT_STYLE.mediaAutoPlay
    };

    const options: ChatTextParserOptions = {
      enableMarkdown: settings.enableMarkdown,
      enableDialogue: settings.enableDialogue,
      extractFrontendHtml: this.foldFrontendHtml,
      symbolRules: this.symbolRules.length > 0 ? this.symbolRules : undefined
    };

    // 打字机揭示中(流式或排空):跳过缓存,直接解析当前已揭示文本
    if (this.typing) {
      this.rawChunks = parseChatChunks(text, options);
      this.chunks = this.resolveLocalImages(this.rawChunks);
      return;
    }

    // 完整内容:使用 LRU 缓存复用(折叠开关进 key,避免两种解析结果互相串)
    const contentHash: number = hashString(text);
    const cacheKey: string = this.buildCacheKey(contentHash, settings);
    const cached: CacheEntry | undefined = ChatRichText.cache.get(cacheKey);
    if (cached !== undefined && cached.contentHash === contentHash) {
      // LRU:命中时移到末尾(Map 保持插入顺序)
      ChatRichText.cache.delete(cacheKey);
      ChatRichText.cache.set(cacheKey, cached);
      this.rawChunks = cached.chunks;
      this.chunks = this.resolveLocalImages(this.rawChunks);
      return;
    }

    // 解析并写入缓存
    const parsed: ChatRenderChunk[] = parseChatChunks(text, options);
    this.evictCacheIfNeeded();
    ChatRichText.cache.set(cacheKey, {
      chunks: parsed,
      contentHash: contentHash
    });

    this.rawChunks = parsed;
    this.chunks = this.resolveLocalImages(parsed);
  }

  /**
   * @Watch 回调:本地图片库映射变化。
   * 只重跑解析映射(从缓存的原始分块),不重新解析文本。
   */
  private onLocalImagesChange(): void {
    this.chunks = this.resolveLocalImages(this.rawChunks);
  }

  /**
   * 把 image 分块里的本地图片/视频名解析成沙箱文件 URI。
   * - 命中:url 换成解析出的 URI;按库内媒体类型决定渲染成图片还是视频
   *   (kind==='video' 的 arkvid: 语法,或名字在库内是 video —— 两者都按视频渲染)
   * - 未命中:url 置空 + alt 记为「未找到图片/视频」,复用 ChatMessageImage 的失败占位
   * - 无本地分块:原样返回(避免无谓分配)
   */
  private resolveLocalImages(chunks: ChatRenderChunk[]): ChatRenderChunk[] {
    let hasLocal: boolean = false;
    for (let i = 0; i < chunks.length; i++) {
      const c: ChatRenderChunk = chunks[i];
      if (c.type === 'image' && (c.kind === 'local' || c.kind === 'video')) {
        hasLocal = true;
        break;
      }
    }
    if (!hasLocal) {
      return chunks;
    }
    const result: ChatRenderChunk[] = [];
    for (let i = 0; i < chunks.length; i++) {
      const c: ChatRenderChunk = chunks[i];
      if (c.type !== 'image' || (c.kind !== 'local' && c.kind !== 'video')) {
        result.push(c);
        continue;
      }
      const resolved: LocalImageResolution | undefined = this.localImages[normalizeImageName(c.name)];
      const url: string = resolved !== undefined ? resolved.uri : '';
      const isVideo: boolean = c.kind === 'video'
        || (resolved !== undefined && resolved.mediaType === 'video');
      const alt: string = url.length > 0
        ? (c.alt.length > 0 ? c.alt : c.name)
        : ('未找到' + (isVideo ? '视频' : '图片') + '「' + c.name + '」');
      const image: ImageChatRenderChunk = {
        type: 'image',
        id: c.id,
        url: url,
        alt: alt,
        kind: isVideo ? 'video' : 'local',
        name: c.name,
        source: c.source
      };
      result.push(image);
    }
    return result;
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
      + (this.foldFrontendHtml ? 'fe1' : 'fe0') + '_'
      + this.buildThemeFingerprint() + '_'
      + this.buildSymbolRulesFingerprint();
  }

  /**
   * 构建自定义符号规则指纹(参与缓存 key)。
   * 只含规则 id(符号对 + 顺序):解析结果只取决于符号对,
   * 颜色由渲染层实时解析,故改色不需要重解析(拖动色盘时不触发整条消息重排)。
   * 无规则时返回 'sym0',保持与旧缓存 key 一致。
   */
  private buildSymbolRulesFingerprint(): string {
    if (this.symbolRules.length === 0) {
      return 'sym0';
    }
    let out: string = 'sym';
    for (let i = 0; i < this.symbolRules.length; i++) {
      out += '|' + this.symbolRules[i].id;
    }
    return out;
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
   * 按规则 id 从当前自定义符号规则中解析颜色。
   * 读 @Prop symbolRules 触发依赖收集,规则改色后已渲染的 Span 立即刷新。
   * 未命中(规则已删除)返回 null,由调用方回退为常规语义色。
   */
  private resolveSymbolRuleColor(ruleId: string): string | null {
    for (let i = 0; i < this.symbolRules.length; i++) {
      const rule: ChatSymbolColorRule = this.symbolRules[i];
      if (rule.id === ruleId) {
        return rule.color;
      }
    }
    return null;
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
    // 自定义符号颜色:用户显式规则优先级最高(覆盖角色独立色与所有语义色)。
    // 颜色在渲染时从 @Prop symbolRules 实时解析(不读片段内的固化值):
    // Span 由稳定 key 复用、不随数据重建,只有读状态变量才能让改色立即生效。
    if (seg.symbolRuleId.length > 0) {
      const symbolColor: string | null = this.resolveSymbolRuleColor(seg.symbolRuleId);
      if (symbolColor !== null) {
        return symbolColor;
      }
      // 规则已被删除:回退为常规语义色(继续走下方分支)
    }

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
        case 'header':
          return $r('app.color.chat_text_emphasis');
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
      case 'header':
        // 加粗/斜体/删除线/标题归入强调色
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

  /**
   * 计算片段字号。标题(#)按级别放大,其余使用基础字号。
   */
  private getSegmentFontSize(base: number, seg: ChatTextSegment): number {
    if (seg.styleType !== 'header') {
      return base;
    }
    const levelStep: number = seg.listLevel <= 1 ? 3 : (seg.listLevel === 2 ? 2 : 1);
    return base + levelStep;
  }

  /**
   * 渲染表格分块:按行列网格对齐,修复表格列错乱。
   * - 每格宽度相等(layoutWeight=1),内容为行内片段(加粗/代码等保留)
   * - 表头行浅灰底 + 加粗;行间细分隔线
   * - 颜色全部使用 app.surface_* 资源,自动适配深色模式
   */
  @Builder
  tableChunk(chunk: TableChatRenderChunk) {
    Column({ space: 2 }) {
      ForEach(chunk.rows, (row: TableChunkRow, rowIndex: number) => {
        Row() {
          ForEach(row.cells, (cellSegs: ChatTextSegment[], _colIndex: number) => {
            Text() {
              ForEach(cellSegs, (seg: ChatTextSegment, spanIndex: number) => {
                Span(seg.text)
                  .fontColor(this.getSegmentColor(seg))
                  .fontSize(this.settings !== null ? this.settings.fontSize : 16)
                  .fontWeight(row.isHeader || seg.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
                  .decoration({
                    type: seg.strike ? TextDecorationType.LineThrough : TextDecorationType.None,
                    color: this.getSegmentColor(seg)
                  })
              }, (seg: ChatTextSegment, spanIndex: number) => spanIndex.toString() + '_' + seg.text.length.toString() + '_' + seg.symbolRuleId)
            }
            .layoutWeight(1)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(row.isHeader ? $r('app.color.app_surface_2') : Color.Transparent)
          }, (_cellSegs: ChatTextSegment[], colIndex: number) => colIndex.toString())
        }
        .width('100%')
        .border({
          width: {
            bottom: rowIndex < chunk.rows.length - 1 ? 0.5 : 0
          },
          color: {
            bottom: $r('app.color.app_surface_3')
          }
        })
      }, (row: TableChunkRow, rowIndex: number) => rowIndex.toString())
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 2, bottom: 4 })
  }

  /** 正文字体族(未设置时回退系统默认;family 变化只影响渲染,不影响分块缓存) */
  private currentFontFamily(): string {
    return this.settings !== null ? this.settings.fontFamily : CHAT_FONT_SYSTEM;
  }

  build() {
    if (this.chunks.length === 0) {
      // 空内容占位
      Text('')
        .fontSize(this.settings !== null ? this.settings.fontSize : 16)
        .height(0)
    } else if (this.chunks.length === 1 && this.chunks[0].type === 'text') {
      // 常用路径(纯文本,含流式打字机):单个 Text 直接读 @State this.chunks[0].segments。
      // 不套外层 @Builder(按值传参不刷新)、不套外层 ForEach(稳定 key 复用不刷新)。
      // Text 节点随 chunks 变化原地更新,Span key 随长度变化触发逐字重绘,流式平滑又刷新;
      // key 还带 symbolRuleId:符号规则新增/删除会改变片段的规则绑定,必须靠 key 变化重建 Span;
      // 而规则只改颜色时不进 key——颜色由 getSegmentColor 读 @Prop 实时解析,原地刷新即可;
      // 且不强制宽度,文本随气泡 maxWidth 自动换行(不溢出)。
      Text() {
        ForEach(this.chunks[0].segments, (seg: ChatTextSegment, index: number) => {
          Span(seg.text)
            .fontColor(this.getSegmentColor(seg))
            .fontSize(this.getSegmentFontSize(this.settings !== null ? this.settings.fontSize : 16, seg))
            .fontFamily(this.currentFontFamily())
            .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
            .decoration({
              type: seg.strike ? TextDecorationType.LineThrough : TextDecorationType.None,
              color: this.getSegmentColor(seg)
            })
        }, (seg: ChatTextSegment, index: number) => index.toString() + '_' + seg.text.length.toString() + '_' + seg.symbolRuleId)
      }
      .lineHeight((this.settings !== null ? this.settings.fontSize : 16) * (this.settings !== null ? this.settings.lineHeight : 1.5))
      .fontFamily(this.currentFontFamily())
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
    } else {
      // 含交互块(折叠块/分支选项):Column + ForEach over chunks。
      // 此时交互块一般已闭合(内容基本定型),不再需要逐字流式,稳定/变化 key 均可。
      Column({ space: 3 }) {
        ForEach(this.chunks, (chunk: ChatRenderChunk, index: number) => {
          if (chunk.type === 'text') {
            Text() {
              ForEach(chunk.segments, (seg: ChatTextSegment, spanIndex: number) => {
                Span(seg.text)
                  .fontColor(this.getSegmentColor(seg))
                  .fontSize(this.getSegmentFontSize(this.settings !== null ? this.settings.fontSize : 16, seg))
                  .fontFamily(this.currentFontFamily())
                  .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
                  .decoration({
                    type: seg.strike ? TextDecorationType.LineThrough : TextDecorationType.None,
                    color: this.getSegmentColor(seg)
                  })
              }, (seg: ChatTextSegment, spanIndex: number) => spanIndex.toString() + '_' + seg.text.length.toString() + '_' + seg.symbolRuleId)
            }
            .lineHeight((this.settings !== null ? this.settings.fontSize : 16) * (this.settings !== null ? this.settings.lineHeight : 1.5))
            .fontFamily(this.currentFontFamily())
            .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
          } else if (chunk.type === 'collapsible') {
            // 展开内容用尾随闭包注入 contentBuilder,嵌套 ChatRichText 复用同一渲染管线
            ChatCollapsibleBlock({
              title: chunk.title
            }) {
              ChatRichText({
                content: chunk.content,
                senderType: this.senderType,
                senderCharacterId: this.senderCharacterId,
                isStreaming: false,
                settings: this.settings,
                colorTheme: this.colorTheme,
                symbolRules: this.symbolRules,
                localImages: this.localImages,
                selectable: true,
                foldFrontendHtml: false,
                onInteractiveAction: this.onInteractiveAction
              })
            }
          } else if (chunk.type === 'branches') {
            ChatBranchBlock({
              options: chunk.options,
              onSelect: this.onInteractiveAction
            })
          } else if (chunk.type === 'image') {
            ChatMessageImage({
              url: chunk.url,
              alt: chunk.alt,
              source: chunk.source,
              // v51: 视频用 Video 组件渲染,默认暂停;是否自动播放跟随 Aa 面板设置
              isVideo: chunk.kind === 'video',
              autoPlayMedia: this.settings !== null ? this.settings.mediaAutoPlay : false,
              // v52: 图片大小跟随聊天外观设置(Aa 面板「图片大小」)
              widthRatio: this.settings !== null
                ? this.settings.imageWidthRatio
                : DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio
            })
          } else {
            // 表格分块:按列对齐渲染
            this.tableChunk(chunk)
          }
        }, (chunk: ChatRenderChunk, index: number) => {
          if (chunk.type === 'text') {
            return 't' + index.toString() + '_' + chunk.segments.length.toString();
          }
          if (chunk.type === 'image') {
            // 本地图与网络图共用 id;把解析后的 url 并入 key,否则图片库变化时子节点被复用而不刷新
            return chunk.id + '_' + chunk.url;
          }
          return chunk.id;
        })
      }
      .alignItems(HorizontalAlign.Start)
    }
  }
}
