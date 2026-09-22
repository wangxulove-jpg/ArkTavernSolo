/**
 * FrontendCardPage 前端页面角色卡渲染页
 *
 * 从当前会话的角色卡读取 extensions.arktavern.frontend(HTML/CSS/JS),
 * 使用 ArkWeb 渲染,并通过 javaScriptProxy 注入 window.arktavern Bridge:
 * - getVersion / getState / setState / getCharacter / send / close
 * App → 页面事件通过 runJavaScript 调用 window.arktavernPush.dispatch(json)。
 *
 * 消息发送走 ChatViewModel.sendExternalText,与正常聊天同链路,
 * 因此前端页发送/接收的消息会同步进聊天气泡流。
 *
 * 安全:
 * - 拦截一切外部导航(onOverrideUrlLoading)
 * - 允许 fileAccess 以支持超大前端页走缓存文件回退加载
 * - 仅加载角色卡内嵌内容,不请求外部资源
 *
 * 契约版本:与 CardFrontendBridge 同步,见 docs/frontend-card-contract.md
 */

import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { CardFrontendBridge, FrontendCardCharacterInfo, extractFrontendHtml } from '../bridge/CardFrontendBridge';
import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { Character } from '../models/Character';
import { ChatMessage } from '../models/ChatMessage';
import { ThemePalette } from '../theme/ThemePalette';

/** AppStorage 中当前活动聊天 ViewModel 的 key(ChatPage 推入本页面读取) */
export const ACTIVE_CHAT_VM_KEY: string = 'activeChatViewModel';

/** 推送事件(kind + 任意 JSON 数据) */
interface PushSnapshotEvent {
  kind: string;
  data: Object;
}

/** message_update 事件 data */
interface MessageSnapshotData {
  generating: boolean;
  lastAssistant: string;
}

/** 注入"接口就绪"探针:页面 JS 可据此自查 Bridge 是否可用 */
const BRIDGE_READY_PROBE: string =
  "window.arktavernReady && window.arktavernReady();";

@Entry
@Component
struct FrontendCardPage {
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State characterName: string = '';
  @State showDebug: boolean = false;
  @State debugLogs: string[] = [];
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: CardFrontendBridge | null = null;
  private frontendHtml: string = '';
  /** 内容是否已发起加载(首次 about:blank onPageEnd 后触发,保证 Web 引擎就绪) */
  private contentLoadStarted: boolean = false;
  /** 页面 JS 是否已就绪(未就绪时事件入队等待) */
  private pageReady: boolean = false;
  private pendingPushes: string[] = [];
  private activeViewModel: ChatViewModel | null = null;
  private disposed: boolean = false;

  aboutToAppear(): void {
    const vm: ChatViewModel | null = AppStorage.get<ChatViewModel>(ACTIVE_CHAT_VM_KEY) ?? null;
    if (vm === null) {
      this.loadError = '未找到活动会话,请从聊天页打开';
      this.isLoading = false;
      return;
    }
    this.activeViewModel = vm;
    this.characterName = vm.characterName;

    const character: Character | null = vm.currentCharacter;
    if (character !== null) {
      this.frontendHtml = extractFrontendHtml(character.extensions);
      const info: FrontendCardCharacterInfo = {
        name: character.name,
        description: character.description,
        personality: character.personality,
        scenario: character.scenario,
        systemPrompt: character.systemPrompt
      };
      const bridge: CardFrontendBridge = new CardFrontendBridge(
        vm,
        info,
        (msg: string): void => {
          this.appendDebugLog(msg);
        }
      );
      bridge.pushFunc = (json: string): void => {
        this.pushToPage(json);
      };
      bridge.closeHandler = (): void => {
        this.goBack();
      };
      bridge.start();
      this.bridge = bridge;
    }

    if (this.frontendHtml.trim().length === 0) {
      this.loadError = '该角色卡没有前端界面(extensions.arktavern.frontend 为空)';
      this.isLoading = false;
      return;
    }
    // 不在此处加载内容:aboutToAppear/onControllerAttached 阶段 Web 引擎尚未完成初始化,
    // 此时调 loadUrl/loadData 会被静默丢弃(文档停留 about:blank → 白屏)。
    // 推迟到首次 about:blank 加载完成(onPageEnd)后再注入内容。
  }

  aboutToDisappear(): void {
    this.releaseBridge();
  }

  /** 返回聊天页(同时释放 Bridge 订阅,避免泄漏) */
  private goBack(): void {
    this.releaseBridge();
    router.back();
  }

  private releaseBridge(): void {
    this.disposed = true;
    if (this.bridge !== null) {
      this.bridge!.dispose();
      this.bridge = null;
    }
    this.pageReady = false;
    this.pendingPushes = [];
    this.activeViewModel = null;
  }

  // ===== 加载 =====

  private async loadFrontendHtml(): Promise<void> {
    const html: string = this.frontendHtml;
    if (html.length === 0) {
      return;
    }
    this.appendDebugLog('loading frontend, size=' + html.length.toString() + 'B');
    // 用 loadData 加载(官方推荐的内联 HTML 原生方案),三个关键点(真机 probe+截图验证):
    // - loadUrl 有 URL 长度限制(超 2048 会被静默丢弃,data:/file: 均复现白屏);
    // - baseUrl 必须非空:否则走 LoadWithData 有缺陷路径(结果为空文档);
    //   传 baseUrl 后走 LoadWithDataAndBaseUrl,引擎将原始 HTML 自行 base64 编码
    //   构造 data URL —— 因此这里传 原始 HTML + encoding='utf-8',切勿自行 base64
    //   (自行编码会被再包一层,页面显示 base64 原文)。
    try {
      this.controller.loadData(html, 'text/html', 'utf-8', 'data:', 'data:');
      this.appendDebugLog('loaded via loadData(raw html, baseUrl=data:)');
    } catch (e) {
      this.failLoad('前端加载失败:' + (e as Error).message);
      return;
    }
    // 兜底:若内容加载被静默丢弃(不再触发 onPageEnd),超时报错,避免无限 loading
    setTimeout(() => {
      if (!this.disposed && !this.pageReady && this.loadError.length === 0) {
        this.failLoad('前端加载超时,请返回重试');
      }
    }, 8000);
  }

  private failLoad(reason: string): void {
    this.loadError = reason;
    this.isLoading = false;
    this.appendDebugLog('load failed: ' + reason);
  }

  // ===== 页面事件就绪 =====

  private onPageEnd(): void {
    if (!this.contentLoadStarted) {
      // 首次 onPageEnd = 初始 about:blank 加载完成,Web 引擎已就绪,此刻注入内容
      this.contentLoadStarted = true;
      this.loadFrontendHtml();
      return;
    }
    this.appendDebugLog('page onPageEnd');
    this.pageReady = true;
    this.isLoading = false;
    for (let i = 0; i < this.pendingPushes.length; i++) {
      this.pushScript(this.pendingPushes[i]);
    }
    this.pendingPushes = [];
    this.pushInitialSnapshot();
  }

  /** 推送一次初始快照(status + 消息),保证页面打开即有数据 */
  private pushInitialSnapshot(): void {
    const vm: ChatViewModel | null = this.activeViewModel;
    if (vm === null) {
      return;
    }
    const statusData: Object = vm.statusState.entries;
    const statusEvent: PushSnapshotEvent = { kind: 'status_update', data: statusData };
    this.pushToPage(JSON.stringify(statusEvent));
    let lastAssistant: string = '';
    const msgs: ChatMessage[] = vm.messages;
    for (let i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].role === 'assistant') {
        lastAssistant = msgs[i].content;
        break;
      }
    }
    const msgData: MessageSnapshotData = { generating: vm.isGenerating, lastAssistant: lastAssistant };
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

  private ensureBridgeProbe(): void {
    this.controller.runJavaScript(BRIDGE_READY_PROBE);
  }

  /** 追加调试日志到浮层(保留最近 60 条) */
  private appendDebugLog(msg: string): void {
    const next: string[] = this.debugLogs.slice();
    next.push(msg);
    if (next.length > 60) {
      next.shift();
    }
    this.debugLogs = next;
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹')
          .fontSize(22)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.goBack();
          })

        Text(this.characterName.length > 0 ? this.characterName + ' · 界面' : '角色界面')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.showDebug ? '隐藏日志' : '调试日志')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.showDebug = !this.showDebug;
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: 4, right: 12 })
      .margin({ top: this.statusBarHeight })
      .alignItems(VerticalAlign.Center)

      // 主体
      if (this.loadError.length > 0) {
        Column() {
          Text('无法打开前端界面')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })
          Text(this.loadError)
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('返回')
            .fontSize(14)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .padding({ left: 24, right: 24 })
            .margin({ top: 20 })
            .onClick(() => {
              this.goBack();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Stack() {
          // ArkWeb 渲染前端页面
          Web({ src: 'about:blank', controller: this.controller })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(true)
            .onPageEnd(() => {
              this.onPageEnd();
              this.ensureBridgeProbe();
            })
            .onErrorReceive((event) => {
              this.appendDebugLog('web error: ' + event.error.getErrorInfo());
            })
            .onConsole((event) => {
              this.appendDebugLog('console: ' + event.message);
              return false;
            })
            .onOverrideUrlLoading((request) => {
              const url: string = request.getRequestUrl();
              // 放行初始内容加载(data:/file:)与 about:blank,否则程序化 loadUrl 会被
              // onOverrideUrlLoading 自身拦截,页面停留在 about:blank 导致白屏。
              if (url === 'about:blank' || url.length === 0 ||
                url.startsWith('data:') || url.startsWith('file:')) {
                return false;
              }
              // 其余(外部 http/https、window.location 跳转等)一律拦截
              this.appendDebugLog('nav blocked: ' + url);
              return true;
            })
            .javaScriptProxy({
              object: this.bridge!,
              name: 'arktavern',
              methodList: ['getVersion', 'getState', 'setState', 'getCharacter', 'send', 'close'],
              controller: this.controller
            })

          // 加载中
          if (this.isLoading) {
            Column() {
              LoadingProgress().width(40).height(40).color(ThemePalette.accentColor(this.effectiveTheme))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          }

          // 调试日志浮层
          if (this.showDebug && this.debugLogs.length > 0) {
            Column() {
              Scroll() {
                Column() {
                  ForEach(this.debugLogs, (log: string, index: number) => {
                    Text(log)
                      .fontSize(10)
                      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                      .width('100%')
                      .textAlign(TextAlign.Start)
                  }, (log: string, index: number) => index.toString())
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              }
              .width('100%')
              .height(120)
              .scrollBar(BarState.Auto)
            }
            .width('100%')
            .backgroundColor('rgba(0,0,0,0.40)')
            .position({ x: 0, y: 0 })
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }
}