/**
 * SessionGroupDialogs 会话列表分组(文件夹)管理弹窗族
 *
 * 聊天页会话列表面板(ChatSessionListPanel)与对话记录 Tab(ChatSessionRootView)共用,
 * 消除两侧近乎全量的重复实现:
 * - SessionGroupCreateDialog  新建分组(标题/占位文案由宿主传入:分组 / 文件夹)
 * - SessionGroupRenameDialog  重命名分组 + 删除入口
 * - SessionGroupDeleteDialog  删除确认(仅解除关联,不删会话)
 * - SessionGroupMoveDialog    移动会话到分组(可选"新建文件夹并移入",按 enableNewFolder 显示)
 *
 * 设计:
 * - 输入与展开态由弹窗自持(@State);可见性由宿主的 if 控制(挂载即重建,等价旧"打开前重置")
 * - 文案差异(分组/文件夹)经 @Prop 传入;主题经 @StorageProp('effectiveTheme') 读取
 * - 非空校验、业务动作与 Toast 全部由宿主回调执行(本文件不持有 VM/服务)
 */

import { WorldGroup } from '../models/WorldGroup';
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct SessionGroupCreateDialog {
  /** 弹窗标题('新建世界分组' / '新建文件夹') */
  @Prop title: string = '新建世界分组';
  /** 输入框占位('分组名称' / '文件夹名称') */
  @Prop placeholder: string = '分组名称';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 取消 */
  onCancel: () => void = () => {};
  /** 确认创建(名称为输入原文,非空校验由宿主执行) */
  onConfirm: (name: string) => void = (_: string) => {};

  /** 新建分组输入 */
  @State groupName: string = '';

  build() {
    Stack() {
      Column() {
        Column() {
          Text(this.title)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: this.placeholder, text: this.groupName })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.groupName = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.onCancel();
              })
            Button('创建')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.onConfirm(this.groupName);
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }
}

@Component
export struct SessionGroupRenameDialog {
  /** 回填的分组名(打开时的当前名称) */
  @Prop initialName: string = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 取消 */
  onCancel: () => void = () => {};
  /** 确认重命名(名称为输入原文,非空校验由宿主执行) */
  onConfirm: (name: string) => void = (_: string) => {};
  /** 点击"删除分组(仅解除关联,不删会话)" */
  onRequestDelete: () => void = () => {};

  /** 重命名分组输入 */
  @State groupName: string = '';

  aboutToAppear(): void {
    this.groupName = this.initialName;
  }

  build() {
    Stack() {
      Column() {
        Column() {
          Text('分组管理')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: '分组名称', text: this.groupName })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.groupName = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.onCancel();
              })
            Button('重命名')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.onConfirm(this.groupName);
              })
          }
          .width('100%')
          .margin({ top: 12 })

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 4 })

          Button('删除分组(仅解除关联,不删会话)')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .height(44)
            .onClick(() => {
              this.onRequestDelete();
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }
}

@Component
export struct SessionGroupDeleteDialog {
  /** 文案名词:'分组' | '文件夹'(标题与正文按名词拼装) */
  @Prop noun: string = '分组';
  /** 目标分组名(正文展示) */
  @Prop groupName: string = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 取消 */
  onCancel: () => void = () => {};
  /** 确认删除(仅解除关联,不删会话) */
  onConfirm: () => void = () => {};

  build() {
    Stack() {
      Column() {
        Column() {
          Text('删除' + this.noun)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text('删除' + this.noun + '仅解除会话与该' + this.noun + '的关联,不会删除任何会话。确定删除"'
            + this.groupName
            + '"吗?')
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .lineHeight(20)
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.onCancel();
              })

            Button('删除')
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.onConfirm();
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }
}

@Component
export struct SessionGroupMoveDialog {
  /** 弹窗标题('移动到分组' / '移动到文件夹') */
  @Prop title: string = '移动到分组';
  /** 目标会话标题(展示,截断) */
  @Prop targetTitle: string = '';
  /** 可选分组列表 */
  @Prop groups: WorldGroup[] = [];
  /** 打开时选中的分组 id(= 会话当前 worldId;空字符串=不分组) */
  @Prop initialWorldId: string = '';
  /** 是否显示"新建文件夹"入口(对话记录 Tab 启用;会话列表面板不启用) */
  @Prop enableNewFolder: boolean = false;
  /** "创建并移入"可用(如分组操作进行中置灰) */
  @Prop canCreateFolder: boolean = true;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 取消 */
  onCancel: () => void = () => {};
  /** 确认移动(空字符串=不分组) */
  onConfirmMove: (worldId: string) => void = (_: string) => {};
  /** 新建文件夹并移入(名称为输入原文,非空校验由宿主执行) */
  onCreateFolderAndMove: (name: string) => void = (_: string) => {};

  /** 移动弹窗中选中的分组 id(空字符串=不分组) */
  @State selectedWorldId: string = '';
  /** 移动弹窗:是否展开"新建文件夹"输入 */
  @State showNewFolderInput: boolean = false;
  /** 移动弹窗:"新建文件夹"输入值 */
  @State newFolderName: string = '';

  aboutToAppear(): void {
    this.selectedWorldId = this.initialWorldId;
  }

  build() {
    Stack() {
      Column() {
        Column() {
          Text(this.title)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })

          Text(this.targetTitle)
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 12 })

          Scroll() {
            Column() {
              // "新建文件夹"入口(展开后输入名称,创建并直接移入)
              if (this.enableNewFolder) {
                this.newFolderSection()
              }

              // "不分组"选项
              Row() {
                Radio({ value: 'none', group: 'sessionGroupMove' })
                  .checked(this.selectedWorldId.length === 0)
                  .onChange((checked: boolean) => {
                    if (checked) {
                      this.selectedWorldId = '';
                    }
                  })
                Text('不分组')
                  .fontSize(14)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .margin({ left: 8 })
              }
              .width('100%')
              .height(44)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.selectedWorldId = '';
              })

              Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

              // 分组列表
              ForEach(this.groups, (g: WorldGroup) => {
                Row() {
                  Radio({ value: g.id, group: 'sessionGroupMove' })
                    .checked(this.selectedWorldId === g.id)
                    .onChange((checked: boolean) => {
                      if (checked) {
                        this.selectedWorldId = g.id;
                      }
                    })
                  Text(g.name)
                    .fontSize(14)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .margin({ left: 8 })
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .height(44)
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.selectedWorldId = g.id;
                })
              }, (g: WorldGroup) => g.id)

              if (this.groups.length === 0) {
                Text('暂无分组,请先点击"新建分组"创建')
                  .fontSize(13)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 8 })
              }
            }
            .width('100%')
          }
          .height(220)
          .scrollBar(BarState.Auto)

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.onCancel();
              })
            Button('移动')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.onConfirmMove(this.selectedWorldId);
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  /** 新建文件夹入口 + 展开后的输入行(仅 enableNewFolder 时渲染;末尾 Divider 保持旧布局) */
  @Builder
  newFolderSection() {
    Row() {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(16)
        .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      Text('+ 新建文件夹')
        .fontSize(14)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ left: 8 })
      Blank()
      Text(this.showNewFolderInput ? '▾' : '▸')
        .fontSize(12)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.showNewFolderInput = !this.showNewFolderInput;
    })

    if (this.showNewFolderInput) {
      Row() {
        TextInput({ placeholder: '文件夹名称', text: this.newFolderName })
          .fontSize(14)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .height(36)
          .layoutWeight(1)
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.newFolderName = value;
          })
        Button('创建并移入')
          .fontSize(13)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(8)
          .height(36)
          .margin({ left: 8 })
          .enabled(this.canCreateFolder)
          .onClick(() => {
            this.onCreateFolderAndMove(this.newFolderName);
          })
      }
      .width('100%')
      .margin({ bottom: 6 })
    }

    Divider().color(ThemePalette.dividerColor(this.effectiveTheme))
  }
}