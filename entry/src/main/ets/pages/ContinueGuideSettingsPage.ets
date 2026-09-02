/**
 * ContinueGuideSettingsPage 续写/代写引导设置
 *
 * 管理聊天输入区的两个 AI 生成引导提示词(全局,跨会话):
 * - 代写引导(IMPRES_GUIDE_KEY):喂给 🎭代写 的 3 候选生成指令
 * - 续写引导(CONTINUE_GUIDE_KEY):喂给 ⚡续写 的单次请求指令
 *
 * 留空则使用 ChatService 内置的默认中文提示词。
 * 这些引导只影响独立生成请求,不进主线对话的缓存前缀,故不影响缓存命中率。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { IMPRES_GUIDE_KEY, CONTINUE_GUIDE_KEY } from '../services/ChatService';
import { ThemePalette } from '../theme/ThemePalette';

@Entry
@Component
struct ContinueGuideSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @State impresGuide: string = '';
  @State continueGuide: string = '';
  @State isLoading: boolean = true;
  @State isSaving: boolean = false;

  private preferences: AppPreferences | null = null;

  aboutToAppear(): void {
    AppServices.whenReady().then((): void => {
      this.preferences = AppServices.getAppPreferences();
      this.loadGuides();
    }).catch((): void => {
      this.isLoading = false;
    });
  }

  private async loadGuides(): Promise<void> {
    if (this.preferences === null) {
      this.isLoading = false;
      return;
    }
    try {
      const impres: string = await this.preferences.getString(IMPRES_GUIDE_KEY, '');
      const cont: string = await this.preferences.getString(CONTINUE_GUIDE_KEY, '');
      this.impresGuide = impres;
      this.continueGuide = cont;
    } catch (_e) {}
    this.isLoading = false;
  }

  private async save(): Promise<void> {
    if (this.preferences === null || this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      await this.preferences.putString(IMPRES_GUIDE_KEY, this.impresGuide.trim());
      await this.preferences.putString(CONTINUE_GUIDE_KEY, this.continueGuide.trim());
      promptAction.showToast({ message: '已保存', duration: 1500 });
      router.back();
    } catch (_e) {
      promptAction.showToast({ message: '保存失败,请重试', duration: 2000 });
    }
    this.isSaving = false;
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text('续写 / 代写引导')
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ right: 40 })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // 说明
            Text('留空则使用内置默认中文提示词。自定义内容会作为“额外引导方向”追加到对应生成的指令中；不影响对话缓存的命中率。')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 12 })

            this.guideCard('代写引导（🎭）', '用于生成可供挑选的用户发言候选。例如：引导语气更俏皮、更简短。', this.impresGuide, (value: string): void => {
              this.impresGuide = value;
            }, 140)

            this.guideCard('续写引导（⚡）', '用于自动生成“用户下一句发言 + 角色回应”。例如：推动剧情发展、制造悬念。', this.continueGuide, (value: string): void => {
              this.continueGuide = value;
            }, 160)

            // 保存
            Button('保存')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor($r('app.color.app_accent'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .enabled(!this.isSaving)
              .onClick((): void => {
                this.save();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 32 })
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  private guideCard(title: string, hint: string, value: string,
    onChange: (v: string) => void, height: number) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 2 })
      Text(hint)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })
      TextArea({ placeholder: '留空则使用默认提示词', text: value })
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .onChange((text: string): void => {
          onChange(text);
        })
        .width('100%')
        .height(height)
        .maxLength(10000)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .margin({ bottom: 12 })
  }
}