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
import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { Character } from '../models/Character';
import { ThemePalette } from '../theme/ThemePalette';

/** AppStorage 中当前活动聊天 ViewModel 的 key(ChatPage 推入本页面读取) */
export const ACTIVE_CHAT_VM_KEY: string = 'activeChatViewModel';

@Entry
@Component
struct FrontendCardPage {
  @State characterName: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 传给 CardFrontendWeb 的引用(普通属性,非状态) */
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
      this.frontendHtml = spec.html;
      this.hideChrome = spec.chrome === 'none';
    }
  }

  aboutToDisappear(): void {
    this.vmRef = null;
  }

  private goBack(): void {
    router.back();
  }

  build() {
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
          vm: this.vmRef,
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
  }
}