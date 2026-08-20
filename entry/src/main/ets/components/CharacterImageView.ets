/**
 * CharacterImageView 角色图片视图
 *
 * UI-3B 纯 UI 组件,不依赖业务 Service / Repository / 数据库。
 *
 * 职责:
 * - 显示角色图片(本地 URI)
 * - 图片加载失败或 URI 为空时显示首字占位
 * - 支持 portrait / thumbnail / cover 三种展示模式
 * - 统一处理 objectFit、圆角、尺寸
 *
 * 禁止:
 * - 打印完整图片路径
 * - 将图片转 Base64 保存到页面状态
 * - 发起网络请求
 * - 修改原始图片文件
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct CharacterImageView {
  /** 图片本地 URI(file://...),为空时显示占位 */
  @Prop @Watch('onImageUriChanged') imageUri: string = '';
  /** 角色名称,用于首字占位和 accessibility */
  @Prop fallbackName: string = '';
  /** 组件宽度(使用 imgWidth 避免与 CustomComponent.width 冲突) */
  imgWidth: Length = 80;
  /** 组件高度(使用 imgHeight 避免与 CustomComponent.height 冲突) */
  imgHeight: Length = 100;
  /** 圆角半径(使用 imgBorderRadius 避免与 CustomComponent.borderRadius 冲突) */
  imgBorderRadius: Length = 8;
  /** 展示模式: portrait(竖版角色列表) / thumbnail(小缩略图) / cover(封面大图) */
  displayMode: 'portrait' | 'thumbnail' | 'cover' = 'portrait';
  /** Image objectFit,默认 Cover 保持比例裁剪 */
  objectFit: ImageFit = ImageFit.Cover;

  /** 图片加载失败状态(内部) */
  @State loadFailed: boolean = false;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    this.loadFailed = false;
  }

  /** 图片 URI 变化时重置加载失败状态,使新图片能重新加载 */
  private onImageUriChanged(): void {
    this.loadFailed = false;
  }

  build(): void {
    Stack() {
      // 有 URI 且未失败时尝试显示图片
      if (this.imageUri.length > 0 && !this.loadFailed) {
        // 用 ForEach + 唯一 key(URI)强制 Image 在图片地址变化时重建,
        // 避免组件复用导致 ArkUI Image 不重新加载本地文件(显示旧图缓存)。
        ForEach([this.imageUri], (uri: string): void => {
          Image(uri)
            .width(this.imgWidth)
            .height(this.imgHeight)
            .objectFit(this.objectFit)
            .borderRadius(this.imgBorderRadius)
            .clip(true)
            .onError(() => {
              this.loadFailed = true;
            })
        }, (uri: string): string => uri)
      }

      // URI 为空或加载失败时显示首字占位
      if (this.imageUri.length === 0 || this.loadFailed) {
        this.fallbackView()
      }
    }
    .width(this.imgWidth)
    .height(this.imgHeight)
    .borderRadius(this.imgBorderRadius)
    .clip(true)
  }

  @Builder
  private fallbackView(): void {
    Column() {
      Text(this.fallbackName.length > 0 ? this.fallbackName.charAt(0) : '?')
        .fontSize(this.resolveFallbackFontSize())
        .fontColor($r('app.color.app_on_accent'))
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
    }
    .width(this.imgWidth)
    .height(this.imgHeight)
    .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
    .borderRadius(this.imgBorderRadius)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 根据展示模式计算占位文字字号 */
  private resolveFallbackFontSize(): number {
    if (this.displayMode === 'cover') {
      return 32;
    }
    if (this.displayMode === 'thumbnail') {
      return 16;
    }
    return 24;
  }
}
