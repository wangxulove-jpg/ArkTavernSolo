/**
 * ChatBranchBlock 可点击分支选项
 *
 * 渲染 SillyTavern 风格的 <branches>[选项1]\n[选项2]</branches>:
 * - 每个选项渲染为一行可点击文本
 * - 点击后通过 onSelect 把该选项文字作为用户消息发送给 AI
 * - 样式要求:不带背景框/边框,随内容自适应宽度,长文本自动换行不超范围
 *
 * 不负责:
 * - 选项解析(由 ChatTextParser.parseBranchOptions 提供)
 * - 实际发送(由调用方注入 onSelect)
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatBranchBlock {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 选项列表 */
  options: string[] = [];
  /** 点击选项回调(通常把选项文字转为用户消息发送给 AI) */
  onSelect?: (text: string) => void;

  build() {
    Column() {
      if (this.options.length > 0) {
        ForEach(this.options, (opt: string) => {
          this.optionText(opt)
        }, (opt: string) => opt)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 2, bottom: 2 })
  }

  @Builder
  optionText(opt: string) {
    Row() {
      Text('▶')
        .fontSize(11)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ right: 8 })
      Text(opt)
        .fontSize(13)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(VerticalAlign.Center)
    .padding({ top: 5, bottom: 5 })
    .onClick(() => {
      if (this.onSelect !== undefined) {
        this.onSelect!(opt);
      }
    })
  }
}