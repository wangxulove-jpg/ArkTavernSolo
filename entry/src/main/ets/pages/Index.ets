/**
 * Index 方舟酒馆入口(UI-1 HDS Immersive Bottom Tabs App Shell)
 *
 * 设计参考:PanoVR2 项目 Index.ets 结构
 *
 * 结构:
 * - 顶层 Stack 包裹 HdsTabs(不再用 Navigation)
 * - 二级页面通过 router.pushUrl 跳转(不再用 NavPathStack)
 * - 每个 TabContent 内部分两层:
 *   1. 不透明背景层(填满全屏,延伸到状态栏区域)
 *   2. 内容层(Scroll 列表等)
 * - 状态栏背景透明(setWindowSystemBarProperties),状态栏图标浮在应用背景上
 * - 不依赖窗口透明,不透出系统壁纸(与 PanoVR2 一致)
 *
 * 沉浸式策略:
 * - HdsTabs barOverlap(true) + barFloatingStyle(IMMERSIVE+EXQUISITE)
 * - expandSafeArea(TOP+BOTTOM) 让 HdsTabs 范围扩展到状态栏和底部手势区
 * - 各 Tab 背景层不透明,延伸到状态栏区域,状态栏图标浮于其上
 */

import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, router } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { registerBuiltinChatFonts } from '../utils/ChatFontRegistry';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';
import { CharacterRootView } from './tabs/CharacterRootView';
import { ChatSessionRootView } from './tabs/ChatSessionRootView';
import { MarketPage } from './tabs/MarketPage';
import { SettingsRootView } from './tabs/SettingsRootView';

const LOG_TAG: string = 'Index';

@Entry
@Component
struct Index {
  /** HdsTabs 控制器,用于编程式切换 Tab */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 当前选中的 Tab 索引(0:角色卡, 1:对话记录, 2:市场, 3:设置) */
  @State selectedTab: number = 0;
  /** 当前有效主题(ARK-UI-THEME-1,响应式驱动 Root Shell) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 分享到达序号(EntryAbility 每次收到系统分享 +1,驱动导入跳转) */
  @StorageProp('pendingShareCardSeq') @Watch('onShareCardArrived') pendingShareSeq: number = 0;
  /** 本页是否已完成首次显示(未显示时到达的分享由 onPageShow 兜底消费) */
  private pageShown: boolean = false;

  async aboutToAppear(): Promise<void> {
    // 注册内置正文字体(霞鹭文楷,需 UI 上下文解析 $rawfile),供聊天"正文字体"设置使用
    registerBuiltinChatFonts();
    try {
      // 确保全局 Service 已就绪(数据库、Preferences 等)
      await AppServices.whenReady();
    } catch (e) {
      // 各 RootView 会处理自己的初始化错误,此处仅确保 AppServices 启动
    }
  }

  /**
   * 从二级页面(角色编辑/导入、聊天等)router.back() 返回时触发。
   *
   * 说明:各 TabContent 内嵌的 RootView 是非 @Entry 组件,没有 onPageShow;
   * 而 @StorageProp @Watch 在页面被覆盖(router.pushUrl 盖住)时部分场景不可靠。
   * 因此在本页面级 onPageShow 兜底递增刷新信号,触发各 Tab 列表重新加载。
   */
  onPageShow(): void {
    Logger.info(LOG_TAG, 'onPageShow fired');
    const charVersion: number = AppStorage.get<number>('characterListVersion') ?? 0;
    AppStorage.setOrCreate<number>('characterListVersion', charVersion + 1);
    const chatVersion: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', chatVersion + 1);
    this.pageShown = true;
    // 冷启动分享:分享数据可能早于本页显示到达,此处兜底消费
    this.openSharedCardImport();
  }

  /** 系统分享到达(应用已运行时):立即进入导入预览 */
  onShareCardArrived(): void {
    if (!this.pageShown) {
      // 页面尚未显示完成,交给 onPageShow 消费
      return;
    }
    this.openSharedCardImport();
  }

  /**
   * 消费待导入的分享文件 URI(消费后清空,避免重复触发)。
   * 有值时切到角色卡 Tab,并进入"添加角色"页自动解析展示导入预览。
   */
  private openSharedCardImport(): void {
    const uri: string = AppStorage.get<string>('pendingShareCardUri') ?? '';
    if (uri.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('pendingShareCardUri', '');
    Logger.info(LOG_TAG, 'shared card import, uri=' + uri);
    this.tabsController.changeIndex(0);
    router.pushUrl({ url: 'pages/AddCharacterPage', params: { shareImportUri: uri } })
      .catch((e: Object): void => {
        Logger.error(LOG_TAG, 'push AddCharacterPage for shared card failed: ' + String(e));
      });
  }

  /** Tab 内容背景色:Tavern 使用酒馆棕,其余走资源限定符 */
  private tabBg(): ResourceColor {
    return ThemePalette.pageBgColor(this.effectiveTheme);
  }

  /** Tab 未选中图标色 */
  private tabIconNormal(): string {
    return this.effectiveTheme === 'tavern' ? ThemePalette.forTheme('tavern').textTertiary : '#667085';
  }

  /** Tab 选中图标色 */
  private tabIconSelected(): string {
    return this.effectiveTheme === 'tavern' ? ThemePalette.forTheme('tavern').accent : '#2F73FF';
  }

  build() {
    Stack() {
      HdsTabs({ controller: this.tabsController }) {
        // ===== Tab 1: 角色卡 =====
        TabContent() {
          this.TabCharacterBuilder()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor([this.tabIconNormal()]),
          selected: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor([this.tabIconSelected()])
        }, $r('app.string.tab_characters')))

        // ===== Tab 2: 对话记录 =====
        TabContent() {
          this.TabSessionsBuilder()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor([this.tabIconNormal()]),
          selected: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor([this.tabIconSelected()])
        }, $r('app.string.tab_sessions')))

        // ===== Tab 3: 市场 =====
        TabContent() {
          this.TabMarketBuilder()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor([this.tabIconNormal()]),
          selected: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor([this.tabIconSelected()])
        }, $r('app.string.tab_market')))

        // ===== Tab 4: 设置 =====
        TabContent() {
          this.TabSettingsBuilder()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.exposure')).fontColor([this.tabIconNormal()]),
          selected: new SymbolGlyphModifier($r('sys.symbol.exposure')).fontColor([this.tabIconSelected()])
        }, $r('app.string.tab_settings')))
      }
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .vertical(false)
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .barFloatingStyle({
        barWidth: {
          smallWidth: 320,
          mediumWidth: 360,
          largeWidth: 420
        },
        barBottomMargin: 24,
        // 不设 gradientMask:浅色 maskColor 在深色模式下会显示为白色边
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      })
      .onChange((index: number) => {
        this.selectedTab = index;
      })
    }
    .width('100%')
    .height('100%')
  }

  // ===== Tab 1: 角色卡 =====
  @Builder
  TabCharacterBuilder() {
    Stack() {
      // 第1层:不透明背景层(填满全屏,延伸到状态栏区域)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.tabBg())

      // 第2层:内容层(角色卡列表)
      CharacterRootView()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== Tab 2: 对话记录 =====
  @Builder
  TabSessionsBuilder() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.tabBg())

      ChatSessionRootView()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== Tab 3: 市场 =====
  @Builder
  TabMarketBuilder() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.tabBg())

      MarketPage()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== Tab 4: 设置 =====
  @Builder
  TabSettingsBuilder() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.tabBg())

      SettingsRootView()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
