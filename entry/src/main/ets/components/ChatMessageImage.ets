/**
 * ChatMessageImage 消息内图片/视频组件
 *
 * 渲染 ChatTextParser 抽出的 image 分块(markdown ![](url) / <img src> / 本地图 ![alt](arkimg:名) /
 * 本地视频 ![alt](arkvid:名),仅 https 网络图允许)。
 *
 * 职责:
 * - 图片:显示网络图片(HTTPS)或本地图片库图片/GIF(file://),宽度随气泡自适应(objectFit Contain 不裁切)
 * - 视频:用 Video 组件播放本地视频;**默认暂停**(仅显示首帧 + 播放角标),点击放大后才播放;
 *   Aa 面板「视频自动播放」开启时气泡内直接播放
 * - 加载期间显示占位(原始语法源码 + 加载动画),加载完成只显示图片;失败/地址缺失显示失败占位
 * - 点击全屏放大,再点(或点背景)收起;开关走 geometryTransition 一镜到底(从图片位置展开,从哪来回哪去)
 * - 全屏预览(图片)支持双指缩放(以手指捏合点为锚点),放大后可单指拖动查看(与手指 1:1)
 *   —— 缩放走布局尺寸、平移走布局 offset,一律不用 scale/translate 变换(见 PITFALLS P-97)
 * - 不缓存图片字节到本地(由系统 Image 组件管理内存缓存,与 MarketCharacterAvatar 同口径)
 *
 * 不复用 MarketCharacterAvatar 的原因:它绑定 MarketCharacter 模型与固定宽高/NSFW 门控语义;
 * 消息内图片是"宽度自适应 + 源码占位 + 一镜到底放大",职责不同。
 */

import { display } from '@kit.ArkUI';

/** 图片加载状态(内部) */
type ImageLoadState = 'loading' | 'loaded' | 'failed';

/** 全屏预览:最大放大倍数 */
const PREVIEW_MAX_SCALE: number = 5;
/** 全屏预览:开关转场时长(ms),geometryTransition 的一镜到底跟随该时长 */
const PREVIEW_TRANSITION_DURATION: number = 300;
/** 取不到屏幕尺寸时的兜底值(vp) */
const FALLBACK_SCREEN_W: number = 360;
const FALLBACK_SCREEN_H: number = 720;
/**
 * 视频默认宽高比(16:9)。
 * ArkUI Video 不上报媒体实际尺寸,气泡与预览统一按此比例框,内部 objectFit Contain 不裁切。
 */
const VIDEO_ASPECT_RATIO: number = 16 / 9;

/**
 * 每张图片一个唯一的共享元素 id。
 * geometryTransition 要求"一进一出"恰好两个组件绑定同一 id,故不能直接用 chunk.id(它只在单条消息内唯一)。
 */
let imageSharedSeq: number = 0;
function nextImageSharedId(): string {
  imageSharedSeq += 1;
  return 'chat-msg-image-' + imageSharedSeq.toString();
}

/** Length → vp 数值(onAreaChange 给的是数字;字符串/资源形态按 0 处理) */
function lengthToNumber(value: Length): number {
  if (typeof value === 'number') {
    return value;
  }
  return 0;
}

/** 当前手势所有有效手指的窗口坐标中点(count = 有效手指数) */
interface FingerMidpoint {
  readonly x: number;
  readonly y: number;
  readonly count: number;
}

/**
 * 取当前手势的手指窗口坐标中点(vp)。
 *
 * 必须逐槽判空:**fingerList 的槽位可以是 undefined**(官方口径:未参与本次手势触发的手指,
 * 其位置为空),只判断 `length` 直接按下标取用会 jscrash
 * —— `TypeError: Cannot read property globalX of undefined`(2026-10-06 真机实测崩过一次)。
 * 非 [0, +∞) 的坐标(undefined/NaN)同样按无效跳过,故本函数只返回确定有效的手指。
 */
function fingerMidpoint(event: GestureEvent): FingerMidpoint {
  const list: FingerInfo[] = event.fingerList;
  let sumX: number = 0;
  let sumY: number = 0;
  let count: number = 0;
  for (let i = 0; i < list.length; i++) {
    const finger: FingerInfo | undefined = list[i];
    if (finger === undefined) {
      continue;
    }
    const x: number = finger.globalX;
    const y: number = finger.globalY;
    if (!(x >= 0) || !(y >= 0)) {
      continue;
    }
    sumX += x;
    sumY += y;
    count++;
  }
  if (count === 0) {
    return { x: 0, y: 0, count: 0 };
  }
  return { x: sumX / count, y: sumY / count, count: count };
}

@Component
export struct ChatMessageImage {
  /** 图片地址:网络 https URL 或本地媒体库的沙箱 file:// URI(由解析层/渲染层保证) */
  @Prop url: string = '';
  /** 替代文本(加载失败占位与无障碍用) */
  @Prop alt: string = '';
  /** 原始语法源码(markdown/HTML 标签原文;未加载时占位展示,使用户知道这里有一张图) */
  @Prop source: string = '';
  /**
   * 是否为视频(chunk.kind === 'video')。
   * true 时用 Video 组件渲染(默认暂停),false 时用 Image(图片/GIF)。
   */
  @Prop isVideo: boolean = false;
  /**
   * 气泡内视频是否自动播放(来自 Aa 面板「视频自动播放」,默认 false)。
   * 关闭时仅显示首帧 + 播放角标,点击放大后才播放。
   */
  @Prop autoPlayMedia: boolean = false;
  /**
   * 宽度占气泡的比例(0.3~1.0)。
   * 来自聊天外观设置(Aa 面板「图片大小」),由 ChatRichText 经 settings 透传。
   */
  @Prop widthRatio: number = 1.0;

  /** 小图加载状态(内部) */
  @State loadState: ImageLoadState = 'loading';
  /** 视频是否正在播放(内部;用于控制播放角标显隐) */
  @State videoPlaying: boolean = false;
  /** 全屏预览是否展开(内部) */
  @State previewVisible: boolean = false;
  /** 预览大图是否加载中(内部) */
  @State previewLoading: boolean = true;
  /** 预览大图尺寸(vp):按缩略图比例 fit 进屏幕,一镜到底的目标 frame 必须展开瞬间就确定 */
  @State previewW: number = 0;
  @State previewH: number = 0;
  /** 预览大图缩放与位移(双指缩放、放大后拖动) */
  @State zoomScale: number = 1;
  @State zoomOffsetX: number = 0;
  @State zoomOffsetY: number = 0;

  /** 本实例的共享元素 id(缩略图 ↔ 预览大图) */
  private sharedId: string = nextImageSharedId();
  /** 缩略图实际显示宽高比(宽/高),用于推算预览大图尺寸;未测得时按 1 */
  private thumbRatio: number = 1;
  /** 屏幕尺寸(vp),拖动限幅用 */
  private screenW: number = FALLBACK_SCREEN_W;
  private screenH: number = FALLBACK_SCREEN_H;
  /** 手势起点快照(缩放/拖动都是累积量,需从起点累加) */
  private pinchStartScale: number = 1;
  /** 上一帧已应用的倍率(逐帧以手指位置为锚点,故需知道"从哪一帧变过来") */
  private pinchLastScale: number = 1;
  /** 拖动起点:画面位移 + 手指的窗口坐标 */
  private panStartX: number = 0;
  private panStartY: number = 0;
  private panOriginX: number = 0;
  private panOriginY: number = 0;
  private panHasOrigin: boolean = false;
  /** 捏合是否进行中(用于让单指拖动让位,避免两指位移被算两遍) */
  private pinchActive: boolean = false;
  /** 气泡内视频控制器(暂停/播放;默认不播放) */
  private readonly videoController: VideoController = new VideoController();
  /** 全屏预览视频控制器(放大后自动播放) */
  private readonly previewVideoController: VideoController = new VideoController();

  /** 图片宽度(百分比字符串;比例只看气泡宽度,不改变高宽比) */
  private imageWidth(): string {
    return Math.round(this.widthRatio * 100).toString() + '%';
  }

  /**
   * 预览大图宽度(未测到屏幕尺寸时退回整屏,避免 0 尺寸)。
   * 放大不用 scale 变换,而是直接改布局尺寸:布局尺寸是唯一无歧义的度量
   * (变换属性的叠加顺序会随实现变化,实测导致拖动不跟手)。
   */
  private previewImageWidth(): Length {
    return this.previewW > 0 ? this.previewW * this.zoomScale : '100%';
  }

  /** 预览大图高度(同宽度说明) */
  private previewImageHeight(): Length {
    return this.previewH > 0 ? this.previewH * this.zoomScale : '100%';
  }

  /** 预览视频宽度(未测到屏幕尺寸时退回整屏,避免 0 尺寸;视频不做缩放,直接用 fit 后尺寸) */
  private previewVideoWidth(): Length {
    return this.previewW > 0 ? this.previewW : '100%';
  }

  /** 预览视频高度(同宽度说明) */
  private previewVideoHeight(): Length {
    return this.previewH > 0 ? this.previewH : '100%';
  }

  /** 占位是否处于失败态(地址缺失或加载失败) */
  private isPlaceholderFailed(): boolean {
    return this.url.length === 0 || this.loadState === 'failed';
  }

  /** 占位状态文案(仅失败态使用):优先用 alt(本地图未命中时上层已写成「未找到图片」) */
  private placeholderStatusText(): string {
    if (this.url.length === 0) {
      return this.alt.length > 0 ? this.alt : '图片不可用';
    }
    return this.alt.length > 0 ? '图片加载失败:' + this.alt : '图片加载失败';
  }

  /** 占位源码文案:优先原始语法,退化到 url/alt */
  private placeholderSourceText(): string {
    if (this.source.length > 0) {
      return this.source;
    }
    return this.url.length > 0 ? this.url : this.alt;
  }

  /** 打开全屏预览:先算好目标 frame(一镜到底开场即需要),再在动画闭包内展开 */
  private openPreview(): void {
    if (this.loadState !== 'loaded') {
      return;
    }
    this.resolvePreviewSize();
    this.resetZoom();
    this.previewLoading = true;
    this.getUIContext().animateTo({
      duration: PREVIEW_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.previewVisible = true;
    });
  }

  /**
   * 关闭全屏预览。
   * 复位缩放放在 onDisappear 而不是这里:预览图 frame 参与一镜到底,收起动画期间改布局尺寸会与
   * 几何转场抢同一份 frame。
   */
  private closePreview(): void {
    if (!this.previewVisible) {
      return;
    }
    this.getUIContext().animateTo({
      duration: PREVIEW_TRANSITION_DURATION,
      curve: Curve.FastOutSlowIn
    }, (): void => {
      this.previewVisible = false;
    });
  }

  /** 收起动画结束:复位缩放/位移,下次打开从头开始 */
  private resetZoom(): void {
    this.zoomScale = 1;
    this.zoomOffsetX = 0;
    this.zoomOffsetY = 0;
    this.pinchLastScale = 1;
    this.panHasOrigin = false;
    this.pinchActive = false;
  }

  /**
   * 计算预览大图尺寸 = 缩略图宽高比 fit 进屏幕。
   * 与 objectFit Contain 的取值一致,保证该节点的 frame 就是图片实际占据的矩形,一镜到底才不会跳变。
   */
  private resolvePreviewSize(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 3;
      this.screenW = d.width / density;
      this.screenH = d.height / density;
    } catch (e) {
      this.screenW = FALLBACK_SCREEN_W;
      this.screenH = FALLBACK_SCREEN_H;
    }
    const ratio: number = this.isVideo
      ? VIDEO_ASPECT_RATIO
      : (this.thumbRatio > 0 ? this.thumbRatio : 1);
    if (this.screenW / this.screenH > ratio) {
      this.previewH = this.screenH;
      this.previewW = this.screenH * ratio;
    } else {
      this.previewW = this.screenW;
      this.previewH = this.screenW / ratio;
    }
  }

  /**
   * 双指缩放:以**手指捏合点**为锚点(不是组件中心),手指按住哪就从哪放大。
   *
   * 全部量都用「窗口坐标」(vp,不受组件变换影响):a = 画面位移(布局 offset)、s = 倍率。
   * 画面上距预览盒中心 v 的一点渲染在「窗口中心 + a + v」;手指窗口位置 F 下那一点 v = F - 窗口中心 - a。
   * 倍率变到 s1 后要让该点仍在 F 下: F = 窗口中心 + a1 + v·(s1/s)
   *   ⇒ a1 = (1 - s1/s)(F - 窗口中心) + (s1/s)·a
   * 逐帧用上一帧倍率 s 计算,故手势中途手指整体平移也能被正确吸收。
   */
  private applyPinch(scale: number, focalX: number, focalY: number): void {
    let next: number = this.pinchStartScale * scale;
    if (next > PREVIEW_MAX_SCALE) {
      next = PREVIEW_MAX_SCALE;
    }
    if (next < 1) {
      next = 1;
    }
    const prev: number = this.pinchLastScale > 0 ? this.pinchLastScale : 1;
    if (next <= 1) {
      // 缩回原始大小:位移必须归零,否则图会停在偏离布局位置的地方
      this.zoomScale = 1;
      this.zoomOffsetX = 0;
      this.zoomOffsetY = 0;
      this.pinchLastScale = 1;
      return;
    }
    const ratio: number = next / prev;
    const offsetX: number = (1 - ratio) * (focalX - this.screenW / 2) + ratio * this.zoomOffsetX;
    const offsetY: number = (1 - ratio) * (focalY - this.screenH / 2) + ratio * this.zoomOffsetY;
    this.zoomScale = next;
    this.zoomOffsetX = this.clampZoomOffset(offsetX, this.previewW, this.screenW, next);
    this.zoomOffsetY = this.clampZoomOffset(offsetY, this.previewH, this.screenH, next);
    this.pinchLastScale = next;
  }

  /**
   * 单指拖动:仅在放大后生效(未放大时图已铺满可视区,拖动无意义)。
   * deltaX/deltaY 是手指在**窗口**里的真实位移(vp),直接作为画面位移 → 严格 1:1 跟手。
   */
  private applyPan(deltaX: number, deltaY: number): void {
    if (this.zoomScale <= 1) {
      return;
    }
    this.zoomOffsetX = this.clampZoomOffset(this.panStartX + deltaX, this.previewW, this.screenW, this.zoomScale);
    this.zoomOffsetY = this.clampZoomOffset(this.panStartY + deltaY, this.previewH, this.screenH, this.zoomScale);
  }

  /** 位移限幅:可移动范围为「放大后的边长 - 屏幕对应边长」的一半(负值取 0,即不许拖动) */
  private clampZoomOffset(value: number, extent: number, screen: number, scale: number): number {
    const limit: number = Math.max(0, (extent * scale - screen) / 2);
    if (value > limit) {
      return limit;
    }
    if (value < -limit) {
      return -limit;
    }
    return value;
  }

  build(): void {
    if (this.url.length === 0) {
      // 地址缺失(本地图未命中):没有可加载对象,直接显示占位
      this.placeholderView()
    } else if (this.isVideo) {
      // 视频:默认暂停(仅首帧 + 播放角标),点击放大后才播放
      this.videoBubble()
    } else {
      Stack({ alignContent: Alignment.Center }) {
        // 图片常驻挂载(加载完成前不可见),占位绘制在其上层;加载完成后占位移除,只剩图片
        Image(this.url)
          .width(this.imageWidth())
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .clip(true)
          // 与预览大图绑定同一 id:开关预览时系统自动做"从图片位置展开/收回"的一镜到底
          .geometryTransition(this.sharedId)
          .onAreaChange((oldArea: Area, newArea: Area) => {
            const w: number = lengthToNumber(newArea.width);
            const h: number = lengthToNumber(newArea.height);
            if (w > 0 && h > 0) {
              this.thumbRatio = w / h;
            }
          })
          .onComplete(() => {
            this.loadState = 'loaded';
          })
          .onError(() => {
            this.loadState = 'failed';
          })
        if (this.loadState !== 'loaded') {
          this.placeholderView()
        }
      }
      .width(this.imageWidth())
      .onClick(() => {
        this.openPreview();
      })
      .bindContentCover(this.previewVisible, this.previewOverlay(), {
        // 一镜到底由 geometryTransition 承担,须关掉系统默认的全屏转场
        modalTransition: ModalTransition.NONE,
        onWillDismiss: (): void => {
          this.closePreview();
        },
        onDisappear: (): void => {
          this.resetZoom();
        }
      })
    }
  }

  /**
   * 占位视图:加载中显示原始源码 + 加载动画;失败/地址缺失显示失败提示 + 原始源码。
   * 固定最小高度,保证图片未就绪时气泡里"看得见这里有一张图"。
   */
  @Builder
  private placeholderView(): void {
    Column({ space: 6 }) {
      if (this.isPlaceholderFailed()) {
        Text('🖼 ' + this.placeholderStatusText())
          .fontSize(13)
          .fontColor($r('app.color.app_text_tertiary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('app.color.app_text_tertiary'))
      }
      Text(this.placeholderSourceText())
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius(8)
  }

  /**
   * 全屏预览层:遮罩/图片任意处点按收起;大图带一镜到底、双指缩放、放大后单指拖动。
   * 预览图加载中显示加载动画(缩略图已缓存时通常一闪而过)。
   */
  @Builder
  private previewOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.app_scrim'))
        .onClick(() => {
          this.closePreview();
        })
      Image(this.url)
        .width(this.previewImageWidth())
        .height(this.previewImageHeight())
        .objectFit(ImageFit.Contain)
        // 放大走布局尺寸(见 previewImageWidth),平移走布局偏移:两者都是布局量,不受图形变换叠加顺序影响
        .offset({ x: this.zoomOffsetX, y: this.zoomOffsetY })
        .geometryTransition(this.sharedId)
        .transition(TransitionEffect.OPACITY)
        .onComplete(() => {
          this.previewLoading = false;
        })
        .onError(() => {
          this.previewLoading = false;
        })
        .onClick(() => {
          this.closePreview();
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchActive = true;
                this.pinchStartScale = this.zoomScale;
                this.pinchLastScale = this.zoomScale;
              })
              .onActionUpdate((event: GestureEvent | undefined) => {
                if (event === undefined || !(event.scale > 0)) {
                  return;
                }
                const mid: FingerMidpoint = fingerMidpoint(event);
                if (mid.count < 2) {
                  return; // 手指数据不全的这一帧不参与锚点计算(避免用单指位置当锚点)
                }
                // 用两指在**窗口**坐标里的中点作锚点:窗口坐标不受组件缩放影响,手指按住哪就从哪放大
                this.applyPinch(event.scale, mid.x, mid.y);
              })
              .onActionEnd(() => {
                this.pinchActive = false;
              })
              .onActionCancel(() => {
                this.pinchActive = false;
              }),
            PanGesture({ fingers: 1 })
              .onActionStart(() => {
                this.panStartX = this.zoomOffsetX;
                this.panStartY = this.zoomOffsetY;
                this.panHasOrigin = false;
              })
              .onActionUpdate((event: GestureEvent | undefined) => {
                if (event === undefined) {
                  return;
                }
                const mid: FingerMidpoint = fingerMidpoint(event);
                // 捏合进行中不响应单指拖动(两指同时移动交由捏合的锚点公式吸收,避免位移被算两遍)
                if (this.pinchActive || mid.count === 0) {
                  return;
                }
                // 取第一帧的窗口坐标作原点,再按窗口坐标差值平移 → 与手指严格 1:1
                if (!this.panHasOrigin) {
                  this.panOriginX = mid.x;
                  this.panOriginY = mid.y;
                  this.panHasOrigin = true;
                  return;
                }
                this.applyPan(mid.x - this.panOriginX, mid.y - this.panOriginY);
              })
          )
        )
      if (this.previewLoading) {
        LoadingProgress()
          .width(56)
          .height(56)
          .color($r('app.color.app_on_accent'))
      }
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY)
  }

  /**
   * 气泡内视频视图:默认暂停,显示首帧 + 播放角标;Aa 面板开启「视频自动播放」时直接播放。
   * 视频尺寸按固定宽高比框(objectFit Contain 不裁切)。
   * 点击整块放大 → 预览层播放。
   */
  @Builder
  private videoBubble(): void {
    if (this.loadState === 'failed') {
      this.placeholderView()
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Video({
          src: this.url,
          controller: this.videoController,
          currentProgressRate: 1.0
        })
          .width('100%')
          .aspectRatio(VIDEO_ASPECT_RATIO)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .clip(true)
          // 默认暂停(autoPlayMedia 关闭);开启后气泡内自动播放
          .autoPlay(this.autoPlayMedia)
          .controls(false)
          .loop(false)
          // 与预览视频绑定同一 id:开关预览时系统自动做"从视频位置展开/收回"的一镜到底
          .geometryTransition(this.sharedId)
          .onPrepared(() => {
            this.loadState = 'loaded';
          })
          .onStart(() => {
            this.videoPlaying = true;
          })
          .onPause(() => {
            this.videoPlaying = false;
          })
          .onFinish(() => {
            this.videoPlaying = false;
          })
          .onError(() => {
            this.loadState = 'failed';
          })
        if (this.loadState === 'loading') {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.app_on_accent'))
        } else if (!this.videoPlaying) {
          // 播放角标:提示"点击放大后可播放"(hitTestBehavior None 让点击穿透到外层)
          Column() {
            Text('▶')
              .fontSize(22)
              .fontColor($r('app.color.app_on_accent'))
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor('rgba(0,0,0,0.45)')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(this.imageWidth())
      .onClick(() => {
        this.openPreview();
      })
      .bindContentCover(this.previewVisible, this.previewVideoOverlay(), {
        modalTransition: ModalTransition.NONE,
        onWillDismiss: (): void => {
          this.closePreview();
        },
        onDisappear: (): void => {
          this.resetZoom();
        }
      })
    }
  }

  /**
   * 视频全屏预览层:遮罩点按收起;视频带一镜到底并**自动播放**,带系统播放控件。
   * 视频不参与双指缩放/拖动(与播放控件冲突),故不绑定手势。
   */
  @Builder
  private previewVideoOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.app_scrim'))
        .onClick(() => {
          this.closePreview();
        })
      Video({
        src: this.url,
        controller: this.previewVideoController,
        currentProgressRate: 1.0
      })
        .width(this.previewVideoWidth())
        .height(this.previewVideoHeight())
        .objectFit(ImageFit.Contain)
        // 放大后自动播放(需求:只有点击放大后才能播放)
        .autoPlay(true)
        .controls(true)
        .loop(false)
        .geometryTransition(this.sharedId)
        .transition(TransitionEffect.OPACITY)
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY)
  }
}