/**
 * ChatCollapsibleBlock 可点击折叠块
 *
 * 渲染 SillyTavern 风格的 <details><summary>标题</summary>内容</details>:
 * - 标题行点击切换展开/折叠(▸/▾)
 * - 展开后的内容由父组件通过 @BuilderParam contentBuilder 注入(由 ChatRichText
 *   用嵌套 ChatRichText 渲染,复用完整聊天渲染管线)
 * - 样式要求:不带背景框/边框,随内容自适应宽度,文字在气泡内自动换行,不超出范围
 *
 * 不负责:
 * - 内容解析/渲染(交给父组件注入的 contentBuilder,避免本组件反向依赖 ChatRichText)
 * - 分支选项(见 ChatBranchBlock)
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatCollapsibleBlock {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 折叠标题(<summary>内容) */
  title: string = '';
  /** 父组件注入的展开内容构建函数(渲染折叠内正文) */
  @BuilderParam contentBuilder: () => void = this.defaultContent;

  /** 是否展开(默认收起) */
  @State expanded: boolean = false;

  /** 默认内容占位(父组件未注入时为空) */
  @Builder
  private defaultContent() {
    Text('')
  }

  build() {
    Column() {
      // 标题行(点击切换展开,无背景框)
      Row() {
        Text(this.expanded ? '▾' : '▸')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ right: 6 })
        Text(this.title.length > 0 ? this.title : '展开')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ top: 4, bottom: 4 })
      .onClick(() => {
        this.expanded = !this.expanded;
      })

      // 展开内容(父组件注入,左缩进以体现归属,无背景框、不强制宽度以避免超出范围)
      if (this.expanded) {
        Column() {
          this.contentBuilder()
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 4, top: 2, bottom: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 2, bottom: 2 })
  }
}