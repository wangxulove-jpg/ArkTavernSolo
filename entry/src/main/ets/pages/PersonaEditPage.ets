/**
 * PersonaEditPage 用户身份编辑页面
 *
 * 支持新建和编辑用户身份(Persona)。
 * 路由参数: { personaId: string } (空字符串=新建模式)
 *
 * 表单字段:
 * - 名称(必填)
 * - 描述(可选)
 * - 注入位置(Disabled/BeforeCharacter/AfterCharacter/AtDepth)
 * - 注入深度(仅 AtDepth 时可见)
 *
 * 主题适配: ThemePalette 统一管理,不散落十六进制颜色
 */

import { PersonaPosition } from '../models/PersonaPosition';
import { Persona, PersonaUpdates, validatePersona } from '../models/Persona';
import { PersonaService } from '../services/PersonaService';
import { AppServices } from '../services/AppServices';
import { router } from '@kit.ArkUI';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'PersonaEditPage';

interface PersonaEditRouteParam {
  personaId: string;
}

/** 表单状态快照(不可变,每次修改产生新对象触发 @State 响应) */
interface PersonaFormState {
  nameInput: string;
  descriptionInput: string;
  position: PersonaPosition;
  depth: number;
}

function emptyFormState(): PersonaFormState {
  return {
    nameInput: '',
    descriptionInput: '',
    position: PersonaPosition.BeforeCharacter,
    depth: 4
  };
}

function copyFormState(src: PersonaFormState): PersonaFormState {
  return {
    nameInput: src.nameInput,
    descriptionInput: src.descriptionInput,
    position: src.position,
    depth: src.depth
  };
}

@Entry
@Component
struct PersonaEditPage {
  @State formState: PersonaFormState = emptyFormState();
  @State isLoading: boolean = true;
  @State isEditing: boolean = false;
  @State errorMessage: string = '';
  @State isSaving: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private readonly service: PersonaService = AppServices.getPersonaService();
  private personaId: string = '';
  private readyHandled: boolean = false;

  aboutToAppear(): void {
    this.handleReady(router.getParams());
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button('取消')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .onClick(() => {
            router.back();
          })

        Blank()

        Text(this.isEditing ? '编辑身份' : '新建身份')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

        Blank()

        Button('保存')
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .enabled(!this.isSaving && this.formState.nameInput.trim().length > 0)
          .key('persona_edit.btn_save')
          .onClick(async () => {
            await this.handleSave();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: this.statusBarHeight + 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(ThemePalette.accentColor(this.effectiveTheme))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage.length > 0 && !this.isEditing) {
        Column() {
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor($r('app.color.app_danger'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding(16)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // 基本信息
            this.basicInfoCard()

            // 注入设置
            this.positionCard()

            // 全局错误
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .margin({ top: 8, bottom: 8 })
                .padding(12)
                .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
                .borderRadius(8)
            }

            Blank().height(this.navigationBarHeight + 16)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  basicInfoCard() {
    Column() {
      Text('基本信息')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 12 })

      // 名称 *
      this.fieldLabel('名称 *')
      TextInput({ placeholder: '输入身份名称', text: this.formState.nameInput })
        .maxLength(100)
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          const updated: PersonaFormState = copyFormState(this.formState);
          updated.nameInput = value;
          this.formState = updated;
        })
        .width('100%')

      // 描述
      this.fieldLabel('描述(可选)')
      TextArea({ placeholder: '输入身份描述,如人物设定、性格、背景等', text: this.formState.descriptionInput })
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          const updated: PersonaFormState = copyFormState(this.formState);
          updated.descriptionInput = value;
          this.formState = updated;
        })
        .width('100%')
        .height(120)
        .maxLength(10000)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .margin({ bottom: 12 })
  }

  @Builder
  positionCard() {
    Column() {
      Text('注入设置')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 12 })

      // 位置选择
      this.fieldLabel('注入位置')
      Text('控制身份描述在提示词中的插入位置')
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      this.positionOption(PersonaPosition.Disabled, '不注入', '身份描述不会出现在提示词中')
      this.positionOption(PersonaPosition.BeforeCharacter, '角色定义之前', '在角色卡描述之前插入身份')
      this.positionOption(PersonaPosition.AfterCharacter, '角色定义之后', '在角色卡描述之后插入身份')
      this.positionOption(PersonaPosition.AtDepth, '聊天历史指定深度', '在聊天历史的指定深度处插入')

      // 深度(仅 AtDepth)
      if (this.formState.position === PersonaPosition.AtDepth) {
        this.fieldLabel('注入深度')
        Text('0 = 聊天历史最底部,数字越大越靠前')
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 6 })
        TextInput({
          placeholder: '输入深度(默认 4)',
          text: this.formState.depth.toString()
        })
          .type(InputType.Number)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onChange((value: string) => {
            const updated: PersonaFormState = copyFormState(this.formState);
            const parsed: number = parseInt(value, 10);
            updated.depth = isNaN(parsed) ? 0 : parsed;
            this.formState = updated;
          })
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
  }

  @Builder
  positionOption(position: PersonaPosition, title: string, subtitle: string) {
    Row() {
      Radio({ value: position.toString(), group: 'persona_position' })
        .checked(this.formState.position === position)
        .onChange((isChecked: boolean) => {
          if (isChecked) {
            const updated: PersonaFormState = copyFormState(this.formState);
            updated.position = position;
            this.formState = updated;
          }
        })

      Column() {
        Text(title)
          .fontSize(14)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text(subtitle)
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 8 })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  fieldLabel(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .fontWeight(FontWeight.Regular)
      .width('100%')
      .margin({ top: 12, bottom: 6 })
  }

  private handleReady(param: Object | undefined): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    if (param === null || param === undefined) {
      this.isEditing = false;
      this.formState = emptyFormState();
      this.isLoading = false;
      return;
    }

    const p: PersonaEditRouteParam = param as PersonaEditRouteParam;
    const id: string = p.personaId ?? '';

    if (id.length === 0) {
      this.isEditing = false;
      this.formState = emptyFormState();
      this.isLoading = false;
      Logger.info(LOG_TAG, 'create mode');
      return;
    }

    // 编辑模式:加载已有数据
    this.personaId = id;
    this.loadPersona(id);
  }

  private async loadPersona(id: string): Promise<void> {
    try {
      const persona: Persona | null = await this.service.getById(id);
      if (persona === null) {
        this.errorMessage = '该身份不存在或已被删除';
        this.isEditing = false;
        this.isLoading = false;
        Logger.warn(LOG_TAG, 'persona not found: ' + id);
        return;
      }
      this.formState = {
        nameInput: persona.name,
        descriptionInput: persona.description,
        position: persona.position,
        depth: persona.depth
      };
      this.isEditing = true;
      Logger.info(LOG_TAG, 'edit mode loaded, name=' + persona.name);
    } catch (e) {
      this.errorMessage = '加载身份失败';
      Logger.error(LOG_TAG, 'loadPersona failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  private async handleSave(): Promise<void> {
    this.isSaving = true;
    this.errorMessage = '';

    try {
      if (this.isEditing) {
        // 更新
        const updates: PersonaUpdates = {
          name: this.formState.nameInput.trim(),
          description: this.formState.descriptionInput,
          position: this.formState.position,
          depth: this.formState.depth
        };
        const persona: Persona | null = await this.service.getById(this.personaId);
        if (persona === null) {
          this.errorMessage = '身份不存在';
          this.isSaving = false;
          return;
        }
        await this.service.update(persona, updates);
      } else {
        // 新建
        await this.service.create(
          this.formState.nameInput.trim(),
          this.formState.descriptionInput,
          '',
          this.formState.position,
          this.formState.depth
        );
      }
      router.back();
    } catch (e) {
      this.errorMessage = String(e).replace('Error: ', '');
      Logger.error(LOG_TAG, 'handleSave failed: ' + String(e));
    } finally {
      this.isSaving = false;
    }
  }
}
