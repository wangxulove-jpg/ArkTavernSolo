/**
 * LorebookSourceEditorPage 世界书源码编辑器
 *
 * 从世界书编辑弹窗"查看源码"进入。以 JSON 源码形式展示/编辑一本世界书,
 * 提供查找 / 替换 / 文字统计(行数、字符、词)等基础编辑能力,可保存回数据库。
 *
 * 路由参数:{ param: { lorebookId: string } }
 *
 * 说明:
 * - 编辑的是整册 JSON;保存时先 JSON.parse 校验,通过后整册替换。维持与导入/解析相同的
 *   白名单语义,无效条目在保存时被跳过。
 * - 只读源码时亦可查看;文本改动实时刷新"行数 / 字符 / 词"统计。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { LorebookViewModel } from '../viewmodels/LorebookViewModel';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookSourceEditorPage';

@Entry
@Component
struct LorebookSourceEditorPage {
  /** 编辑器源码文本 */
  @State sourceText: string = '';
  @State isLoading: boolean = true;
  /** 顶部区域提示(加载/保存错误) */
  @State infoText: string = '';

  // ===== 查找/替换 =====
  @State findBarOpen: boolean = false;
  @State replaceBarOpen: boolean = false;
  @State findQuery: string = '';
  @State replaceQuery: string = '';
  @State matchesTotal: number = 0;
  @State matchIndex: number = 0;

  // ===== 统计 =====
  @State lineCount: number = 1;
  @State charCount: number = 0;
  @State wordCount: number = 0;
  @State showStatsDialog: boolean = false;

  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private vm: LorebookViewModel = new LorebookViewModel(
    AppServices.getLorebookService(),
    AppServices.getCharacterService()
  );
  private lorebookId: string = '';
  private textAreaController: TextAreaController = new TextAreaController();
  private matchStart: number[] = [];
  private matchEnd: number[] = [];

  async aboutToAppear(): Promise<void> {
    let id: string = '';
    try {
      const params = router.getParams() as Record<string, Object>;
      const param: Record<string, Object> = params?.['param'] as Record<string, Object>;
      const v: Object | undefined = param?.['lorebookId'];
      if (typeof v === 'string') {
        id = v as string;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'parse param failed: ' + String(e));
    }
    this.lorebookId = id;
    if (id.length === 0) {
      this.infoText = '参数错误:缺少世界书 ID';
      this.isLoading = false;
      return;
    }
    try {
      // 把字符串内部的 \n / \t 转义序列还原为真实换行/制表,便于阅读(不改变内容语义)
      this.sourceText = unpackJsonForDisplay(await this.vm.loadLorebookSource(id));
      this.recomputeStats();
      this.isLoading = false;
    } catch (e) {
      this.infoText = (e as Error).message ?? '加载失败';
      this.isLoading = false;
    }
  }

  /** 文本变化时刷新统计与匹配。 */
  private onTextChange(value: string): void {
    this.sourceText = value;
    this.recomputeStats();
    this.recomputeMatches(false);
  }

  // ===== 统计 =====

  private recomputeStats(): void {
    const text: string = this.sourceText;
    let lines: number = 1;
    if (text.length === 0) {
      lines = 1;
    } else {
      lines = 0;
      for (let i = 0; i < text.length; i++) {
        if (text.charAt(i) === '\n') {
          lines++;
        }
      }
      lines++;
    }
    this.lineCount = lines;
    this.charCount = text.length;
    this.wordCount = countWords(text);
  }

  /** 打开统计弹窗。 */
  private openStats(): void {
    this.recomputeStats();
    this.showStatsDialog = true;
  }

  // ===== 查找 =====

  private openFindBar(): void {
    this.findBarOpen = !this.findBarOpen;
    this.recomputeMatches();
  }

  private openReplaceBar(): void {
    this.replaceBarOpen = !this.replaceBarOpen;
    this.recomputeMatches();
  }

  /** 根据 findQuery 重新计算匹配位置。 */
  private recomputeMatches(autoSelect: boolean = true): void {
    this.matchStart = [];
    this.matchEnd = [];
    if (this.findQuery.length === 0 || this.sourceText.length === 0) {
      this.matchesTotal = 0;
      this.matchIndex = 0;
      return;
    }
    const lower: string = this.sourceText.toLowerCase();
    const lq: string = this.findQuery.toLowerCase();
    const step: number = Math.max(1, lq.length);
    let from: number = 0;
    let j: number = lower.indexOf(lq, from);
    while (j >= 0) {
      this.matchStart.push(j);
      this.matchEnd.push(j + lq.length);
      from = j + step;
      j = lower.indexOf(lq, from);
    }
    this.matchesTotal = this.matchStart.length;
    this.matchIndex = this.matchesTotal > 0 ? 1 : 0;
    if (autoSelect && this.matchesTotal > 0) {
      this.selectMatch(0);
    }
  }

  private selectMatch(idx: number): void {
    if (idx < 0 || idx >= this.matchStart.length) {
      return;
    }
    this.matchIndex = idx + 1;
    const s: number = this.matchStart[idx];
    const e: number = this.matchEnd[idx];
    // 先滚动到命中处再选中,保证"下一个/上一个"能真正跳转到对应位置并高亮选中
    this.textAreaController.caretPosition(s);
    this.textAreaController.setTextSelection(s, e);
  }

  private prevMatch(): void {
    if (this.matchesTotal === 0) {
      return;
    }
    const cur: number = Math.max(0, this.matchIndex - 1);
    const next: number = (cur - 1 + this.matchesTotal) % this.matchesTotal;
    this.selectMatch(next);
  }

  private nextMatch(): void {
    if (this.matchesTotal === 0) {
      return;
    }
    const cur: number = Math.max(0, this.matchIndex - 1);
    const next: number = (cur + 1) % this.matchesTotal;
    this.selectMatch(next);
  }

  // ===== 替换 =====

  /** 替换当前选中匹配。 */
  private replaceCurrent(): void {
    if (this.findQuery.length === 0 || this.matchesTotal === 0) {
      return;
    }
    const idx: number = Math.max(0, this.matchIndex - 1);
    const s: number = this.matchStart[idx];
    const e: number = this.matchEnd[idx];
    this.sourceText = this.sourceText.substring(0, s)
      + this.replaceQuery + this.sourceText.substring(e);
    this.recomputeStats();
    this.recomputeMatches();
  }

  /** 全部替换(大小写不敏感)。 */
  private replaceAll(): void {
    if (this.findQuery.length === 0) {
      return;
    }
    this.sourceText = caseInsensitiveReplaceAll(this.sourceText, this.findQuery, this.replaceQuery);
    this.recomputeStats();
    this.recomputeMatches();
  }

  // ===== 保存 =====

  private async handleSave(): Promise<void> {
    if (this.lorebookId.length === 0) {
      return;
    }
    this.infoText = '';
    try {
      // 把显示用的真实换行/制表重新转义为 JSON 转义序列,恢复为合法 JSON 再保存
      const strictJson: string = repackJsonForSave(this.sourceText);
      await this.vm.saveLorebookSource(this.lorebookId, strictJson);
      promptAction.showToast({ message: '保存成功', duration: 1500 });
      router.back();
    } catch (e) {
      this.infoText = (e as Error).message ?? '保存失败';
    }
  }

  build() {
    Column() {
      // ===== 顶部栏:返回 + 标题 + 保存 =====
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
          .padding(8)
          .onClick(() => { router.back(); })

        Text($r('app.string.lorebook_source_editor_title'))
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8 })

        Button($r('app.string.lorebook_source_save'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .height(34)
          .padding({ left: 14, right: 14 })
          .borderRadius(17)
          .enabled(!this.isLoading)
          .onClick(() => { void this.handleSave(); })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 8, left: 8, right: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // ===== 工具栏 =====
      Row() {
        this.toolButton($r('app.string.lorebook_source_find'), () => { this.openFindBar(); })
        this.toolButton($r('app.string.lorebook_source_replace'), () => { this.openReplaceBar(); })
        this.toolButton($r('app.string.lorebook_source_stats'), () => { this.openStats(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .justifyContent(FlexAlign.Start)

      // ===== 查找栏 =====
      if (this.findBarOpen) {
        Row() {
          TextInput({ placeholder: $r('app.string.lorebook_source_find_placeholder'), text: this.findQuery })
            .fontSize(13)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.findQuery = v;
              this.recomputeMatches();
            })
          Text(this.matchesTotal > 0
            ? this.matchIndex.toString() + '/' + this.matchesTotal.toString()
            : '0/0')
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ left: 6 })
          this.smallIconButton('▲', () => { this.prevMatch(); })
          this.smallIconButton('▼', () => { this.nextMatch(); })
          Text($r('app.string.lorebook_source_close'))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .padding({ left: 6 })
            .onClick(() => { this.findBarOpen = false; this.recomputeMatches(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 4 })
      }

      // ===== 替换栏 =====
      if (this.replaceBarOpen) {
        Row() {
          TextInput({ placeholder: $r('app.string.lorebook_source_find_placeholder'), text: this.findQuery })
            .fontSize(13)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.findQuery = v;
              this.recomputeMatches();
            })
        }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
        Row() {
          TextInput({ placeholder: $r('app.string.lorebook_source_replace_placeholder'), text: this.replaceQuery })
            .fontSize(13)
            .layoutWeight(1)
            .onChange((v: string) => { this.replaceQuery = v; })
          Text($r('app.string.lorebook_source_replace_one'))
            .fontSize(13)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .padding({ left: 8 })
            .onClick(() => { this.replaceCurrent(); })
          Text($r('app.string.lorebook_source_replace_all'))
            .fontSize(13)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .padding({ left: 8 })
            .onClick(() => { this.replaceAll(); })
        }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
      }

      // ===== 状态行:行数 / 字符 / 词 =====
      Row() {
        Text(this.lineCount.toString())
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ right: 4 })
        Text($r('app.string.lorebook_source_lines_suffix'))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ right: 12 })
        Text(this.charCount.toString())
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ right: 4 })
        Text($r('app.string.lorebook_source_chars_suffix'))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ right: 12 })
        Text(this.wordCount.toString())
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ right: 4 })
        Text($r('app.string.lorebook_source_words_suffix'))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 6 })

      // ===== 错误/提示 =====
      if (this.infoText.length > 0) {
        Text(this.infoText)
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      // ===== 编辑器 =====
      if (this.isLoading) {
        Column() {
          Text($r('app.string.lorebook_source_loading'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        TextArea({
          placeholder: $r('app.string.lorebook_source_editor_placeholder'),
          text: this.sourceText,
          controller: this.textAreaController
        })
          .fontSize(12)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .onChange((value: string) => { this.onTextChange(value); })
          .layoutWeight(1)
          .width('100%')
      }

      // ===== 统计弹窗 =====
      if (this.showStatsDialog) {
        this.statsDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    // 只扩展顶部安全区;底部不扩展,避免弹出键盘时页面内容被顶出屏幕
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  // ===== 工具栏按钮 =====

  @Builder
  toolButton(label: ResourceStr, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(ThemePalette.accentColor(this.effectiveTheme))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 4 })
      .onClick(onTap)
  }

  @Builder
  smallIconButton(label: string, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .margin({ left: 4 })
      .onClick(onTap)
  }

  // ===== 统计弹窗 =====

  @Builder
  statsDialog() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => { this.showStatsDialog = false; })

      Column() {
        Text($r('app.string.lorebook_source_stats_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 14 })

        this.statRow(this.lineCount.toString(), $r('app.string.lorebook_source_lines_suffix'))
        this.statRow(this.charCount.toString(), $r('app.string.lorebook_source_chars_suffix'))
        this.statRow(this.wordCount.toString(), $r('app.string.lorebook_source_words_suffix'))

        Button($r('app.string.dialog_done'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .margin({ top: 12 })
          .onClick(() => { this.showStatsDialog = false; })
      }
      .width('82%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
  }

  @Builder
  statRow(count: string, suffix: ResourceStr) {
    Row() {
      Text(count)
        .fontSize(16)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .fontWeight(FontWeight.Medium)
      Text(suffix)
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ left: 6 })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }
}

/** 计数词:英文单词数 + 中文字符数(中文无空格,逐字计)。 */
function countWords(text: string): number {
  let count: number = 0;
  const latin: Array<string> | null = text.match(/[A-Za-z0-9_']+/g);
  if (latin !== null) {
    count += latin.length;
  }
  const cjk: Array<string> | null = text.match(/[\u4e00-\u9fff]/g);
  if (cjk !== null) {
    count += cjk.length;
  }
  return count;
}

/** 大小写不敏感的整文本替换(逐处匹配,保留其余文本大小写)。 */
function caseInsensitiveReplaceAll(
  text: string,
  query: string,
  replacement: string
): string {
  if (query.length === 0) {
    return text;
  }
  const lower: string = text.toLowerCase();
  const lq: string = query.toLowerCase();
  const parts: string[] = [];
  let pos: number = 0;
  let j: number = lower.indexOf(lq, pos);
  while (j >= 0) {
    parts.push(text.substring(pos, j));
    parts.push(replacement);
    pos = j + lq.length;
    j = lower.indexOf(lq, pos);
  }
  parts.push(text.substring(pos));
  return parts.join('');
}

/**
 * 将严格 JSON 源码还原为便于阅读的显示文本:
 * 仅把字符串字面量内部的 \n / \t 转义序列还原为真实换行/制表;结构缩进与其它转义原样保留。
 * 通过进入/退出双引号字符串跟踪字符串边界,避免误改字符串外的结构缩进。
 */
function unpackJsonForDisplay(json: string): string {
  const out: string[] = [];
  const len: number = json.length;
  let inString: boolean = false;
  let i: number = 0;
  while (i < len) {
    const c: string = json.charAt(i);
    if (inString) {
      if (c === '\\' && i + 1 < len) {
        const next: string = json.charAt(i + 1);
        if (next === 'n') {
          out.push('\n');
          i += 2;
          continue;
        }
        if (next === 't') {
          out.push('\t');
          i += 2;
          continue;
        }
        // 其它转义(\\ \" \/ \b \f \r \uXXXX 等)原样保留
        out.push(c);
        out.push(next);
        i += 2;
        continue;
      }
      if (c === '"') {
        inString = false;
      }
      out.push(c);
      i += 1;
      continue;
    }
    if (c === '"') {
      inString = true;
    }
    out.push(c);
    i += 1;
  }
  return out.join('');
}

/**
 * 把显示文本(字符串内部可能是真实换行/制表)还原为合法 JSON:
 * 仅把字符串字面量内部出现的真实换行/制表转义为 \n / \t;其余字符与转义原样保留。
 */
function repackJsonForSave(text: string): string {
  const out: string[] = [];
  const len: number = text.length;
  let inString: boolean = false;
  let i: number = 0;
  while (i < len) {
    const c: string = text.charAt(i);
    if (inString) {
      if (c === '\\') {
        // 原样保留反斜杠,后续字符按普通字符继续处理(已有的 \\ 等转义不会被二次改写)
        out.push(c);
        i += 1;
        continue;
      }
      if (c === '"') {
        inString = false;
        out.push(c);
        i += 1;
        continue;
      }
      if (c === '\n') {
        out.push('\\');
        out.push('n');
        i += 1;
        continue;
      }
      if (c === '\t') {
        out.push('\\');
        out.push('t');
        i += 1;
        continue;
      }
      out.push(c);
      i += 1;
      continue;
    }
    if (c === '"') {
      inString = true;
    }
    out.push(c);
    i += 1;
  }
  return out.join('');
}