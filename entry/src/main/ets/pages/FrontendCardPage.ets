/**
 * FrontendCardPage 前端页面角色卡渲染页(fullscreen 模式)
 *
 * 从当前会话的角色卡读取 extensions.arktavern.frontend(HTML/CSS/JS),
 * 复用 CardFrontendWeb 组件渲染 + Bridge 注入。
 * 顶栏由本页提供;内容区(CardFrontendWeb)与 ChatPage 面板模式共用同一套渲染/Bridge 逻辑。
 *
 * 外观:frontend.chrome='none' 时不渲染 App 顶栏(沉浸),内容区直接铺满
 * (仍从状态栏下方开始,底部保持原样);退出靠系统返回手势/返回键或页面 close()。
 *
 * 消息发送走 ChatViewModel.sendExternalText,与正常聊天同链路;
 * 页面内自绘对话可调 window.arktavern.getMessages() 拉历史(契约 v2)。
 *
 * 契约版本:与 CardFrontendBridge 同步,见 docs/frontend-card-contract.md
 */

import { router } from '@kit.ArkUI';
import { CardFrontendWeb } from '../components/CardFrontendWeb';
import { extractFrontendSpec, FrontendSpec } from '../bridge/CardFrontendBridge';
import { detectStFrontendHtml, StFrontendFallback } from '../bridge/StFrontendFallback';
import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { Character } from '../models/Character';
import { ThemePalette } from '../theme/ThemePalette';

/** AppStorage 中当前活动聊天 ViewModel 的 key(ChatPage 推入本页面读取) */
export const ACTIVE_CHAT_VM_KEY: string = 'activeChatViewModel';

/**
 * 「浮窗」切换请求序号(AppStorage):
 * 本页「浮窗」按钮置为递增值并 router.back(),ChatPage.onPageShow 读到 >0 即
 * 消费(清零)并以 panel 模式重新打开前端——实现全屏页 ↔ 聊天页浮窗的显示方式切换。
 */
export const FRONTEND_OPEN_PANEL_SEQ: string = 'frontendOpenPanelSeq';

@Entry
@Component
struct FrontendCardPage {
  @State characterName: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 传给 CardFrontendWeb 的宿主引用(普通属性,非状态;结构上满足 FrontendCardHost) */
  private vmRef: ChatViewModel | null = null;
  private frontendHtml: string = '';
  /** 是否隐藏 App 顶栏(卡声明 chrome:'none' → 沉浸) */
  private hideChrome: boolean = false;

  aboutToAppear(): void {
    const vm: ChatViewModel | null = AppStorage.get<ChatViewModel>(ACTIVE_CHAT_VM_KEY) ?? null;
    if (vm === null) {
      return;
    }
    this.vmRef = vm;
    this.characterName = vm.characterName;
    const character: Character | null = vm.currentCharacter;
    if (character !== null) {
      const spec: FrontendSpec = extractFrontendSpec(character.extensions);
      if (spec.html.trim().length > 0) {
        this.frontendHtml = spec.html;
        this.hideChrome = spec.chrome === 'none';
      } else {
        // 原版 ST 卡散落前端回退检测(开场白/备用开场白/美化正则):无 arktavern 声明时兜底接入;
        // 兜底卡 chrome 按 auto 处理(带 App 顶栏,便于返回与切换浮窗)
        const fallback: StFrontendFallback | null = detectStFrontendHtml(character);
        if (fallback !== null) {
          this.frontendHtml = fallback.html;
        }
      }
    }
  }

  aboutToDisappear(): void {
    this.vmRef = null;
  }

  private goBack(): void {
    router.back();
  }

  /** 「浮窗」切换:置请求序号并返回聊天页,由 ChatPage.onPageShow 以 panel 模式重新打开 */
  private switchToPanel(): void {
    const seq: number = AppStorage.get<number>(FRONTEND_OPEN_PANEL_SEQ) ?? 0;
    AppStorage.setOrCreate<number>(FRONTEND_OPEN_PANEL_SEQ, seq + 1);
    this.goBack();
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
      // 顶栏(chrome:'none' 的沉浸卡不渲染,内容直接铺满)
      if (!this.hideChrome) {
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

          // 浮窗切换:回聊天页并以内嵌面板模式打开同一份前端页面
          Text('浮窗')
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .height(30)
            .padding({ left: 12, right: 12 })
            .borderRadius(15)
            .textAlign(TextAlign.Center)
            .margin({ left: 8 })
            .onClick(() => {
              this.switchToPanel();
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 4, right: 12 })
        .margin({ top: this.statusBarHeight })
        .alignItems(VerticalAlign.Center)
      } else {
        // 沉浸模式:仅避让状态栏,其余交给页面自身布局
        Row()
          .width('100%')
          .height(this.statusBarHeight)
      }

      // 主体
      if (this.vmRef !== null && this.frontendHtml.trim().length > 0) {
        CardFrontendWeb({
          host: this.vmRef,
          html: this.frontendHtml,
          onClose: (): void => {
            this.goBack();
          }
        })
          .width('100%')
          .layoutWeight(1)
      } else {
        Column() {
          Text('无法打开前端界面')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })
          Text('该角色卡没有前端界面,或会话尚未就绪')
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
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      // 沉浸模式(chrome=none)没有 App 顶栏:右下角半透明「浮窗」悬浮钮,
      // 避开卡页面自身按钮的常见位置(左上/右上),不遮挡主内容
      if (this.hideChrome && this.vmRef !== null && this.frontendHtml.trim().length > 0) {
        Text('⧉ 浮窗')
          .fontSize(12)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor('rgba(30,30,38,0.55)')
          .height(30)
          .padding({ left: 12, right: 12 })
          .borderRadius(15)
          .textAlign(TextAlign.Center)
          .margin({ right: 14, bottom: 28 })
          .onClick(() => {
            this.switchToPanel();
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }
}