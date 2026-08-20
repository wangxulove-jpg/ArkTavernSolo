/**
 * MarketCharacterAvatar 市场角色头像组件
 *
 * 显示远程市场角色头像,处理加载失败和占位。
 *
 * 职责:
 * - 显示远程头像(HTTPS)
 * - 加载失败显示首字占位(与本地角色头像一致风格)
 * - URL 为空时直接显示占位
 * - 支持列表缩略图与详情大图两种尺寸
 * - 支持延迟加载大图(NSFW 未确认前不加载)
 *
 * 安全:
 * - 不缓存图片字节到本地(由系统 Image 组件管理内存缓存)
 * - 不把远程 URL 写入本地角色
 * - 仅显示 HTTPS URL(http:// 拒绝)
 * - allowLoad=false 时不发起任何图片加载请求,仅显示占位
 */

import { MarketCharacter } from '../models/MarketCharacter';
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct MarketCharacterAvatar {
  /** 市场角色(用于获取 avatarUrl 与 name) */
  item: MarketCharacter | null = null;
  /** 头像宽度 */
  imgWidth: Length = 80;
  /** 头像高度 */
  imgHeight: Length = 100;
  /** 圆角 */
  imgBorderRadius: Length = 12;
  /** 占位文字字号 */
  fallbackFontSize: number = 24;
  /**
   * 是否允许加载远程图片。
   * - true:按正常流程加载 HTTPS 头像
   * - false:始终显示占位,不发起图片加载(NSFW 未确认前传入 false,避免预加载敏感内容)
   * 使用 @Prop + @Watch 以便在父组件切换状态时重置内部状态并触发重新加载。
   */
  @Prop @Watch('onAllowLoadChange') allowLoad: boolean = true;
  /** 加载失败状态(内部) */
  @State loadFailed: boolean = false;
  /** 当前正在加载的 URL,用于检测 URL 变化重置失败状态 */
  @State currentUrl: string = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    this.loadFailed = false;
    this.currentUrl = this.resolveUrl();
  }

  /**
   * allowLoad 变化时回调:重置加载失败状态,重新解析 URL。
   * 典型场景:NSFW 确认后从 false 切到 true,触发头像加载。
   */
  private onAllowLoadChange(): void {
    this.loadFailed = false;
    this.currentUrl = this.resolveUrl();
  }

  /**
   * 解析当前头像 URL。
   * 仅 HTTPS 链接有效,http:// 与空字符串均视为不可用。
   * allowLoad=false 时强制返回空字符串,确保不发起图片加载。
   */
  private resolveUrl(): string {
    if (!this.allowLoad) {
      return '';
    }
    if (this.item === null) {
      return '';
    }
    const url: string = this.item.avatarUrl;
    if (url.startsWith('https://')) {
      return url;
    }
    return '';
  }

  build(): void {
    Stack() {
      if (this.resolveUrl().length > 0 && !this.loadFailed && this.resolveUrl() === this.currentUrl) {
        Image(this.resolveUrl())
          .width(this.imgWidth)
          .height(this.imgHeight)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.imgBorderRadius)
          .clip(true)
          .onError(() => {
            this.loadFailed = true;
          })
      } else {
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
      Text(this.resolveFallbackText())
        .fontSize(this.fallbackFontSize)
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

  /**
   * 获取占位文字(角色名首字,无则'?')。
   */
  private resolveFallbackText(): string {
    if (this.item === null) {
      return '?';
    }
    const name: string = this.item.name;
    if (name.length === 0) {
      return '?';
    }
    return name.charAt(0);
  }
}
