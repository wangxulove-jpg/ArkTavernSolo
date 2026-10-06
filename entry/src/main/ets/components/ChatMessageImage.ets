/**
 * ChatMessageImage 消息内网络图片组件
 *
 * 渲染 ChatTextParser 抽出的 image 分块(markdown ![](url) / <img src>,仅 https)。
 *
 * 职责:
 * - 显示网络图片(HTTPS),宽度随气泡自适应(objectFit Contain 不裁切)
 * - 加载失败显示占位(不塌陷为空白)
 * - 不缓存图片字节到本地(由系统 Image 组件管理内存缓存,与 MarketCharacterAvatar 同口径)
 *
 * 不复用 MarketCharacterAvatar 的原因:它绑定 MarketCharacter 模型与固定宽高/NSFW 门控语义;
 * 消息内图片是"宽度自适应 + alt 语义",职责不同。
 */

@Component
export struct ChatMessageImage {
  /** 图片 URL(已保证 https:// 前缀,由解析层过滤) */
  @Prop url: string = '';
  /** 替代文本(加载失败占位与无障碍用) */
  @Prop alt: string = '';
  /** 加载失败状态(内部) */
  @State loadFailed: boolean = false;

  build(): void {
    if (!this.loadFailed && this.url.length > 0) {
      Image(this.url)
        .width('100%')
        .objectFit(ImageFit.Contain)
        .borderRadius(8)
        .clip(true)
        .onError(() => {
          this.loadFailed = true;
        })
    } else {
      Column() {
        Text('🖼 图片加载失败' + (this.alt.length > 0 ? ':' + this.alt : ''))
          .fontSize(13)
          .fontColor($r('app.color.app_text_tertiary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(72)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius(8)
    }
  }
}
