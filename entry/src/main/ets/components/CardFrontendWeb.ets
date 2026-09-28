/**
 * CardFrontendWeb 前端页面 ArkWeb 渲染组件(全屏页 FrontendCardPage 与 ChatPage 面板模式共用)
 *
 * 用 ArkWeb 渲染角色卡 extensions.arktavern.frontend 的 HTML,
 * 通过 javaScriptProxy 注入 window.arktavern Bridge(getVersion/getState/getStatusSchema/
 * setState/getCharacter/getMessages/send/close),App → 页面事件经 runJavaScript 调用
 * window.arktavernPush.dispatch(json)。
 *
 * 设计:
 * - host 为宿主契约(FrontendCardHost)引用(普通属性,父子共享同一实例;
 *   页面直接传入 ChatViewModel),bridge 由本组件自建
 * - html 为提取出的完整 HTML 字符串
 * - 关键加载:loadData(rawHtml,'text/html','utf-8','data:','data:') 在首次 about:blank
 *   onPageEnd 时触发(Web 引擎就绪),规避 loadUrl URL 长度限制与 LoadWithData 缺陷(见 FrontendCardPage)
 * - 双指缩放:加载前剥掉 HTML 里的 user-scalable=no / maximum-scale,并开启 Web 手势缩放,
 *   使卡片页面可双指放大(画面变大,元素更易点按)
 *
 * 契约版本:与 CardFrontendBridge 同步,见 docs/frontend-card-contract.md
 */

import { webview } from '@kit.ArkWeb';
import {
  CardFrontendBridge,
  FrontendCardHost,
  FrontendCardCharacterInfo
} from '../bridge/CardFrontendBridge';
import { Character } from '../models/Character';
import { ChatMessage } from '../models/ChatMessage';
import { ThemePalette } from '../theme/ThemePalette';

/** 推送事件(kind + 任意 JSON 数据) */
interface PushSnapshotEvent {
  kind: string;
  data: Object;
}

/** message_update 事件 data */
interface MessageSnapshotData {
  generating: boolean;
  lastAssistant: string;
  messageCount: number;
}

/** 注入"接口就绪"探针:页面 JS 可据此自查 Bridge 是否可用 */
const BRIDGE_READY_PROBE: string =
  'window.arktavernReady && window.arktavernReady();';

@Component
export struct CardFrontendWeb {
  /** 宿主契约引用(对象引用,父子共享,页面直接传 ChatViewModel)。页面 JS 的 Bridge 由本组件自建 */
  host: FrontendCardHost | null = null;
  /** 要渲染的完整 HTML(extensions.arktavern.frontend 内容) */
  html: string = '';
  /**
   * 宿主是否处于"活跃展示"状态(面板模式:展开中;全屏页:恒 true)。
   * 转为 false 时主动 blur 页面内焦点,避免保活隐藏后键盘留在页面上不收起。
   */
  @Prop @Watch('onActiveChanged') active: boolean = true;
  /** 关闭回调:全屏页返回 / 面板模式收起面板 */
  onClose: () => void = (): void => {};

  @State isLoading: boolean = true;
  @State loadError: string = '';
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: CardFrontendBridge | null = null;
  /** 内容是否已发起加载(首次 about:blank onPageEnd 后触发,保证 Web 引擎就绪) */
  private contentLoadStarted: boolean = false;
  /** 页面 JS 是否已就绪(未就绪时事件入队等待) */
  private pageReady: boolean = false;
  private pendingPushes: string[] = [];
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.setupBridge();
  }

  aboutToDisappear(): void {
    this.releaseBridge();
  }

  /**
   * 活跃态变化:宿主收起(保活隐藏)时 blur 页面内焦点,
   * 否则 ArkWeb 仍持有输入焦点,收起面板后系统键盘不会自动收起。
   */
  onActiveChanged(): void {
    if (this.active || this.disposed) {
      return;
    }
    this.blurActiveElement();
  }

  /** 让页面内当前焦点元素失焦(收起安全区内的输入法) */
  private blurActiveElement(): void {
    try {
      this.controller.runJavaScript(
        'try{document.activeElement&&document.activeElement.blur&&document.activeElement.blur();}catch(e){}');
    } catch (_e) {
      // 页面尚未加载完成时忽略
    }
  }

  /** 基于当前 host 的角色卡构建 Bridge(每次进入重建,确保订阅与会话绑定) */
  private setupBridge(): void {
    this.disposed = false;
    this.pageReady = false;
    this.pendingPushes = [];
    this.contentLoadStarted = false;
    this.isLoading = true;
    this.loadError = '';
    const character: Character | null =
      this.host !== null ? this.host!.currentCharacter : null;
    if (this.host === null || character === null || this.html.trim().length === 0) {
      this.loadError = '该角色卡没有可用的前端界面';
      this.isLoading = false;
      return;
    }
    const info: FrontendCardCharacterInfo = {
      name: character.name,
      description: character.description,
      personality: character.personality,
      scenario: character.scenario,
      systemPrompt: character.systemPrompt
    };
    const bridge: CardFrontendBridge = new CardFrontendBridge(
      this.host!, info, (msg: string): void => { /* 调试日志静默 */ }
    );
    bridge.pushFunc = (json: string): void => {
      this.pushToPage(json);
    };
    bridge.closeHandler = (): void => {
      if (!this.disposed) {
        this.onClose();
      }
    };
    bridge.start();
    this.bridge = bridge;
  }

  private releaseBridge(): void {
    this.disposed = true;
    if (this.bridge !== null) {
      this.bridge!.dispose();
      this.bridge = null;
    }
    this.pageReady = false;
    this.pendingPushes = [];
  }

  // ===== 加载 =====

  private loadFrontendHtml(): void {
    const html: string = this.withPinchZoomAllowed(this.html);
    if (html.length === 0) {
      this.failLoad('前端 HTML 为空');
      return;
    }
    // 用 loadData 加载(官方推荐的内联 HTML 原生方案):
    // - loadUrl 有 URL 长度限制(超 2048 会被静默丢弃,data:/file: 均复现白屏)
    // - baseUrl 必须非空(走 LoadWithDataAndBaseUrl 可靠路径),此处传原始 HTML + utf-8
    //   (引擎自行 base64 编码构造 data URL;自行 base64 会被再包一层显示原文)
    try {
      this.controller.loadData(html, 'text/html', 'utf-8', 'data:', 'data:');
    } catch (e) {
      this.failLoad('前端加载失败:' + (e as Error).message);
      return;
    }
    // 兜底:若内容加载被静默丢弃(不再触发 onPageEnd),超时报错,避免无限 loading
    setTimeout(() => {
      if (!this.disposed && !this.pageReady && this.loadError.length === 0) {
        this.failLoad('前端加载超时,请关闭后重试');
      }
    }, 8000);
  }

  private failLoad(reason: string): void {
    this.loadError = reason;
    this.isLoading = false;
  }

  /**
   * 放宽卡片 HTML 的 viewport 限制,使双指缩放可用。
   * 角色卡(尤其 AI 生成)常写 user-scalable=no / maximum-scale=1 禁用缩放,
   * 这里在加载前剥掉这两项(保留 width / initial-scale,不影响原有布局),交由 ArkWeb 手势缩放处理。
   */
  private withPinchZoomAllowed(html: string): string {
    return html
      .replace(new RegExp('user-scalable\\s*=\\s*(?:no|0)(\\s*,\\s*)?', 'gi'), '')
      .replace(new RegExp('maximum-scale\\s*=\\s*[0-9.]+(\\s*,\\s*)?', 'gi'), '');
  }

  private onPageEnd(): void {
    if (!this.contentLoadStarted) {
      // 首次 onPageEnd = 初始 about:blank 加载完成,Web 引擎已就绪,此刻注入内容
      this.contentLoadStarted = true;
      this.loadFrontendHtml();
      return;
    }
    this.pageReady = true;
    this.isLoading = false;
    for (let i = 0; i < this.pendingPushes.length; i++) {
      this.pushScript(this.pendingPushes[i]);
    }
    this.pendingPushes = [];
    this.pushInitialSnapshot();
  }

  /** 推送一次初始快照(schema + status + 消息),保证页面打开即有数据 */
  private pushInitialSnapshot(): void {
    const host: FrontendCardHost | null = this.host;
    if (host === null) {
      return;
    }
    // 先推送声明式 Schema 快照(页面可据此重绘状态表单);无声明则为空数组
    const schemaData: Object = JSON.parse(host.statusSchemaJson());
    const schemaEvent: PushSnapshotEvent = { kind: 'schema_update', data: schemaData };
    this.pushToPage(JSON.stringify(schemaEvent));
    const statusData: Object = host.statusState.entries;
    const statusEvent: PushSnapshotEvent = { kind: 'status_update', data: statusData };
    this.pushToPage(JSON.stringify(statusEvent));
    let lastAssistant: string = '';
    const msgs: ChatMessage[] = host.messages;
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === 'assistant') {
        lastAssistant = msgs[i].content;
        break;
      }
    }
    const msgData: MessageSnapshotData = {
      generating: host.isGenerating,
      lastAssistant: lastAssistant,
      messageCount: msgs.length
    };
    const messageEvent: PushSnapshotEvent = { kind: 'message_update', data: msgData };
    this.pushToPage(JSON.stringify(messageEvent));
  }

  /** Bridge 事件入口:就绪则立即推送,否则入队 */
  private pushToPage(json: string): void {
    if (this.pageReady) {
      this.pushScript(json);
    } else {
      this.pendingPushes.push(json);
    }
  }

  /** 执行页面 JS 分发:json 作为 JS 字符串字面量安全转义 */
  private pushScript(json: string): void {
    if (this.disposed || this.pageReady === false) {
      return;
    }
    const literal: string = JSON.stringify(json);
    const code: string =
      'window.arktavernPush && window.arktavernPush.dispatch(' + literal + ');';
    this.controller.runJavaScript(code);
  }

  build() {
    Column() {
      if (this.bridge === null) {
        // Bridge 不可用(无角色卡/前端为空):静处显示错误,不渲染 Web
        Column() {
          Text('无法打开前端界面')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })
          Text(this.loadError)
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.loadError.length > 0) {
        Column() {
          Text('无法打开前端界面')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })
          Text(this.loadError)
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Stack() {
          Web({ src: 'about:blank', controller: this.controller })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(true)
            // 允许双指手势缩放卡片页面(默认即为 true,此处显式声明意图)
            .zoomAccess(true)
            .onPageEnd(() => {
              this.onPageEnd();
            })
            .onErrorReceive((event) => {
              this.failLoad('web error: ' + event.error.getErrorInfo());
            })
            .onConsole((event) => {
              return false;
            })
            .onOverrideUrlLoading((request) => {
              const url: string = request.getRequestUrl();
              // 放行初始内容加载(data:/file:)与 about:blank,其余外部导航一律拦截
              if (url === 'about:blank' || url.length === 0
                || url.startsWith('data:') || url.startsWith('file:')) {
                return false;
              }
              return true;
            })
            .javaScriptProxy({
              object: this.bridge!,
              name: 'arktavern',
              methodList: ['getVersion', 'getState', 'getStatusSchema',
                'setState', 'getCharacter', 'getMessages', 'send', 'appendInteraction', 'close'],
              controller: this.controller
            })

          // 加载中
          if (this.isLoading) {
            LoadingProgress().width(40).height(40)
              .color(ThemePalette.accentColor(this.effectiveTheme))
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 暴露给父级:页面 JS 就绪后触发一次 Bridge 探针(供页面 onPageEnd 后自查) */
  ensureBridgeProbe(): void {
    if (!this.disposed) {
      this.controller.runJavaScript(BRIDGE_READY_PROBE);
    }
  }
}