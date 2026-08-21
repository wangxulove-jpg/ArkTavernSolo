/**
 * PersonaListPage 用户身份列表页面
 *
 * 显示所有 Persona,支持设为默认、新建、编辑、删除。
 * 通过 PersonaViewModel 操作,不直接访问 Repository 或 Service。
 *
 * 视觉风格与 PromptPresetListPage 保持一致:
 * - SymbolGlyph chevron_left 返回按钮
 * - ThemePalette 统一主题色
 * - 带边框的卡片式条目
 * - FAB 新建按钮
 */

import { PersonaViewModel } from '../viewmodels/PersonaViewModel';
import { AppServices } from '../services/AppServices';
import { Persona } from '../models/Persona';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

interface PersonaEditRouteParam {
  personaId: string;
}

@Entry
@Component
struct PersonaListPage {
  @State viewModel: PersonaViewModel = new PersonaViewModel(AppServices.getPersonaService());
  @State refreshKey: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  private hasInitialized: boolean = false;

  onPageShow(): void {
    if (this.hasInitialized) {
      this.viewModel.load();
    } else {
      this.hasInitialized = true;
      this.viewModel.load();
    }
  }

  build() {
    Stack() {
      Column() {
        // 导航栏
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text('用户身份')
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 40 })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // 错误提示
        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        // 内容区
        if (this.viewModel.loading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(ThemePalette.accentColor(this.effectiveTheme))
            Text('加载中...')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.viewModel.personas.length === 0) {
          Column() {
            Text('暂无身份')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            Text('点击右下角按钮创建第一个身份')
              .fontSize(13)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.viewModel.personas, (persona: Persona) => {
                this.personaCard(persona);
              }, (persona: Persona) => persona.id + '_' + this.refreshKey.toString())
              Blank().height(80);
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16, top: 8 })
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')

      // FAB 新建按钮
      if (!this.viewModel.loading) {
        Button('+ 新建身份')
          .fontSize(14)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ x: '70%', y: '90%' })
          .key('persona_list.fab_create')
          .onClick(() => {
            router.pushUrl({
              url: 'pages/PersonaEditPage',
              params: { personaId: '' } as PersonaEditRouteParam
            });
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  personaCard(persona: Persona) {
    Row() {
      Column() {
        Text(persona.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (persona.description.length > 0) {
          Text(persona.description)
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }

        Row() {
          Text(this.viewModel.getPositionLabel(persona.position))
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })

          if (this.viewModel.isDefault(persona)) {
            Text('默认')
              .fontSize(12)
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .margin({ top: 6 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 操作按钮
      Row() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(18)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .padding(8)
          .key('persona_list.btn_edit_' + persona.id)
          .onClick(() => {
            router.pushUrl({
              url: 'pages/PersonaEditPage',
              params: { personaId: persona.id } as PersonaEditRouteParam
            });
          })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius($r('app.float.app_radius_md'))
    .border({
      width: 1,
      color: ThemePalette.dividerColor(this.effectiveTheme)
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .margin({ bottom: 8 })
    .onClick(() => {
      this.viewModel.setDefault(persona);
      this.refreshKey++;
    })
  }
}
