/**
 * HistoricalMessageEditDialog 历史 User 消息编辑弹窗(T-6.4B-3.1)
 *
 * 用于编辑历史 User Message 内容,点击"保存并生成"后创建新 Branch。
 *
 * 功能:
 * - 预填原始 User 正文
 * - 多行文本输入,保留换行
 * - 取消按钮:关闭弹窗,不修改任何数据
 * - "保存并生成"按钮:内容非空且变化时启用,点击后回调
 * - 操作进行中禁止重复提交(isSubmitting)
 * - 空内容时禁用确认
 *
 * 不依赖:
 * - Service / Repository / Network
 * - 业务逻辑
 *
 * 数据流:
 * - ChatPage 通过 CustomDialogController 打开
 * - 用户点击"保存并生成"后通过 onConfirm 回调返回编辑后内容
 * - ChatPage 负责调用 ViewModel.editUserMessageAndGenerate
 */

import { ThemePalette } from '../theme/ThemePalette';

const COLOR_MASK: string = 'rgba(0,0,0,0.4)';
const COLOR_BUTTON_TEXT: string = '#FFFFFF';

const RES_TITLE: string = 'chat_edit_message_title';
const RES_PLACEHOLDER: string = 'chat_edit_message_placeholder';
const RES_CANCEL: string = 'chat_edit_message_cancel';
const RES_CONFIRM: string = 'chat_edit_message_save_and_generate';
const RES_SUBMITTING: string = 'chat_edit_message_submitting';

@CustomDialog
export struct HistoricalMessageEditDialog {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  controller: CustomDialogController;
  /** 原始 User 正文(预填) */
  originalContent: string = '';
  /** 是否正在提交(禁止重复点击) */
  isSubmitting: boolean = false;
  /** 确认回调,返回编辑后的内容 */
  onConfirm: (editedContent: string) => void = (_: string) => {};
  /** 取消回调 */
  onCancel: () => void = () => {};

  @State private editingContent: string = '';
  @State private localSubmitting: boolean = false;

  aboutToAppear(): void {
    this.editingContent = this.originalContent;
    this.localSubmitting = this.isSubmitting;
  }

  build() {
    Column() {
      // 标题
      Text($r('app.string.' + RES_TITLE))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 20, bottom: 16 })

      // 输入框
      TextArea({ text: this.editingContent, placeholder: $r('app.string.' + RES_PLACEHOLDER) })
        .fontSize(14)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
        .padding(10)
        .width('100%')
        .height(180)
        .margin({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.editingContent = value;
        })

      // 按钮区
      Row() {
        Button(this.localSubmitting
          ? $r('app.string.' + RES_SUBMITTING)
          : $r('app.string.' + RES_CANCEL))
          .fontSize(15)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .layoutWeight(1)
          .height(44)
          .enabled(!this.localSubmitting)
          .onClick(() => {
            this.handleCancel();
          })

        Divider()
          .vertical(true)
          .height(24)
          .color(ThemePalette.dividerColor(this.effectiveTheme))

        Button(this.localSubmitting
          ? $r('app.string.' + RES_SUBMITTING)
          : $r('app.string.' + RES_CONFIRM))
          .fontSize(15)
          .backgroundColor(this.canConfirm() ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .fontColor(COLOR_BUTTON_TEXT)
          .layoutWeight(1)
          .height(44)
          .enabled(this.canConfirm())
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .margin({ top: 20 })
      .border({ width: { top: 1 }, color: ThemePalette.dividerColor(this.effectiveTheme) })
    }
    .width('88%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
  }

  /**
   * 是否可以确认:
   * - 不在提交中
   * - 内容非空(去空白后)
   * - 内容有变化(去前后空白后不等于原文)
   */
  private canConfirm(): boolean {
    if (this.localSubmitting) {
      return false;
    }
    const trimmed: string = this.editingContent.trim();
    if (trimmed.length === 0) {
      return false;
    }
    return trimmed !== this.originalContent.trim();
  }

  private handleConfirm(): void {
    if (!this.canConfirm()) {
      return;
    }
    const trimmed: string = this.editingContent.trim();
    this.localSubmitting = true;
    // 通知 Controller 关闭弹窗(ChatPage 在 onConfirm 中执行实际操作)
    this.onConfirm(trimmed);
    this.controller.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller.close();
  }
}
