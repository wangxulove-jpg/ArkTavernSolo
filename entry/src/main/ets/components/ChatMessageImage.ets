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
  /** 图片地址:网络 https URL 或本地图片库的沙箱 file:// URI(由解析层/渲染层保证) */
  @Prop url: string = '';
  /** 替代文本(加载失败占位与无障碍用) */
  @Prop alt: string = '';
  /**
   * 宽度占气泡的比例(0.3~1.0)。
   * 来自聊天外观设置(Aa 面板「图片大小」),由 ChatRichText 经 settings 透传。
   */
  @Prop widthRatio: number = 1.0;
  /** 加载失败状态(内部) */
  @State loadFailed: boolean = false;

  /** 图片宽度(百分比字符串;比例只看气泡宽度,不改变高宽比) */
  private imageWidth(): string {
    return Math.round(this.widthRatio * 100).toString() + '%';
  }

  build(): void {
    if (!this.loadFailed && this.url.length > 0) {
      Image(this.url)
        .width(this.imageWidth())
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
      .width(this.imageWidth())
      .height(72)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius(8)
    }
  }
}
