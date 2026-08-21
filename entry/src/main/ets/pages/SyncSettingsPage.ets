import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { SyncViewModel, ConnectionStatus } from '../viewmodels/SyncViewModel';
import { WebDavSyncService, SyncResult } from '../services/sync/WebDavSyncService';
import { SyncConfigStore } from '../storage/SyncConfigStore';

@Entry
@Component
struct SyncSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @State serverUrl: string = '';
  @State username: string = '';
  @State appPassword: string = '';
  @State remotePath: string = '';
  @State autoSyncEnabled: boolean = false;
  @State wifiOnly: boolean = true;
  @State lastSyncTime: string = '';
  @State connectionStatus: string = 'untested';
  @State isSyncing: boolean = false;
  @State syncProgress: number = 0;
  @State syncMessage: string = '';
  @State resultMessage: string = '';
  @State isLoading: boolean = true;
  @State passwordVisible: boolean = true;

  private viewModel: SyncViewModel | null = null;

  aboutToAppear(): void {
    AppServices.whenReady().then(() => {
      const syncService: WebDavSyncService = AppServices.getWebDavSyncService();
      const configStore: SyncConfigStore = AppServices.getSyncConfigStore();
      this.viewModel = new SyncViewModel(syncService, configStore);
      this.viewModel.loadConfig().then(() => {
        this.syncFromViewModel();
        this.isLoading = false;
      });
    }).catch(() => {
      this.isLoading = false;
    });
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.serverUrl = this.viewModel.serverUrl;
    this.username = this.viewModel.username;
    this.appPassword = this.viewModel.appPassword;
    this.remotePath = this.viewModel.remotePath;
    this.autoSyncEnabled = this.viewModel.autoSyncEnabled;
    this.wifiOnly = this.viewModel.wifiOnly;
    this.lastSyncTime = this.viewModel.lastSyncTime;
    this.connectionStatus = this.viewModel.connectionStatus;
  }

  private syncToViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.serverUrl = this.serverUrl;
    this.viewModel.username = this.username;
    this.viewModel.appPassword = this.appPassword;
    this.viewModel.remotePath = this.remotePath;
    this.viewModel.autoSyncEnabled = this.autoSyncEnabled;
    this.viewModel.wifiOnly = this.wifiOnly;
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.page_primary_text')])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.sync_settings_title'))
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor($r('app.color.page_primary_text'))
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
            .color($r('app.color.page_secondary_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            this.buildWebDavConfigSection()
            this.buildSyncOptionsSection()
            this.buildManualActionsSection()
            this.buildProgressSection()
            this.buildNotesSection()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 32 })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  buildWebDavConfigSection() {
    Text($r('app.string.sync_webdav_config_section'))
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.page_primary_text'))
      .width('100%')
      .margin({ bottom: 12 })

    Column() {
      Text($r('app.string.sync_server_url_label'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_secondary_text'))
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: 'https://dav.jianguoyun.com/dav/', text: this.serverUrl })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('100%')
        .onChange((value: string) => {
          this.serverUrl = value;
        })

      Text($r('app.string.sync_username_label'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_secondary_text'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      TextInput({ placeholder: $r('app.string.sync_username_placeholder'), text: this.username })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('100%')
        .onChange((value: string) => {
          this.username = value;
        })

      Text($r('app.string.sync_password_label'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_secondary_text'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      Row() {
        TextInput({ placeholder: $r('app.string.sync_password_placeholder'), text: this.appPassword })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(44)
          .layoutWeight(1)
          .type(this.passwordVisible ? InputType.Normal : InputType.Password)
          .onChange((value: string) => {
            this.appPassword = value;
          })
        Text(this.passwordVisible ? '隐藏' : '显示')
          .fontSize(14)
          .fontColor($r('app.color.app_accent'))
          .margin({ left: 8 })
          .onClick(() => {
            this.passwordVisible = !this.passwordVisible;
          })
      }
      .width('100%')

      Text($r('app.string.sync_remote_path_label'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_secondary_text'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      TextInput({ placeholder: '/ArkTavernSolo/', text: this.remotePath })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('100%')
        .onChange((value: string) => {
          this.remotePath = value;
        })

      Button($r('app.string.sync_test_connection'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .width('100%')
        .margin({ top: 12 })
        .enabled(this.connectionStatus !== 'testing')
        .onClick(() => {
          this.syncToViewModel();
          if (this.viewModel !== null) {
            this.viewModel.testConnection().then((success: boolean) => {
              this.connectionStatus = this.viewModel !== null ? this.viewModel.connectionStatus : 'untested';
              if (success) {
                promptAction.showToast({ message: $r('app.string.sync_connection_success') });
              } else {
                promptAction.showToast({ message: $r('app.string.sync_connection_failed') });
              }
            });
          }
        })
    }
    .width('100%')
    .padding(12)
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: 1, color: $r('app.color.app_divider') })
  }

  @Builder
  buildSyncOptionsSection() {
    Text($r('app.string.sync_options_section'))
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.page_primary_text'))
      .width('100%')
      .margin({ top: 24, bottom: 12 })

    Column() {
      Row() {
        Text($r('app.string.sync_wifi_only'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.wifiOnly })
          .onChange((isOn: boolean) => {
            this.wifiOnly = isOn;
            this.syncToViewModel();
            if (this.viewModel !== null) {
              this.viewModel.saveConfig();
            }
          })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      Row() {
        Text($r('app.string.sync_auto_on_launch'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.autoSyncEnabled })
          .onChange((isOn: boolean) => {
            this.autoSyncEnabled = isOn;
            this.syncToViewModel();
            if (this.viewModel !== null) {
              this.viewModel.saveConfig();
            }
          })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      if (this.lastSyncTime.length > 0) {
        Text($r('app.string.sync_last_sync_time', this.lastSyncTime))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.page_secondary_text'))
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: 1, color: $r('app.color.app_divider') })
  }

  @Builder
  buildManualActionsSection() {
    Text($r('app.string.sync_manual_section'))
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.page_primary_text'))
      .width('100%')
      .margin({ top: 24, bottom: 12 })

    Column() {
      Button($r('app.string.sync_upload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .width('100%')
        .margin({ bottom: 8 })
        .enabled(!this.isSyncing)
        .onClick(() => {
          this.doSync('upload');
        })

      Button($r('app.string.sync_download'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .width('100%')
        .margin({ bottom: 8 })
        .enabled(!this.isSyncing)
        .onClick(() => {
          this.doSync('download');
        })

      Button($r('app.string.sync_bidirectional'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .width('100%')
        .enabled(!this.isSyncing)
        .onClick(() => {
          this.doSync('bidirectional');
        })
    }
    .width('100%')
    .padding(12)
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: 1, color: $r('app.color.app_divider') })
  }

  @Builder
  buildProgressSection() {
    if (this.isSyncing || this.resultMessage.length > 0) {
      Column() {
        if (this.isSyncing) {
          Progress({ value: this.syncProgress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .color($r('app.color.app_accent'))
            .margin({ bottom: 8 })

          Text(this.syncMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.page_secondary_text'))
            .width('100%')
        }

        if (this.resultMessage.length > 0 && !this.isSyncing) {
          Text(this.resultMessage)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.page_primary_text'))
            .width('100%')
            .margin({ top: 8 })
        }
      }
      .width('100%')
      .padding(12)
      .borderRadius($r('app.float.app_radius_md'))
      .backgroundColor($r('app.color.app_surface_1'))
      .border({ width: 1, color: $r('app.color.app_divider') })
      .margin({ top: 16 })
    }
  }

  @Builder
  buildNotesSection() {
    Column() {
      Text($r('app.string.sync_notes_title'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.page_primary_text'))
        .width('100%')
        .margin({ bottom: 8 })

      Text($r('app.string.sync_notes_content'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_secondary_text'))
        .width('100%')
        .lineHeight(20)
    }
    .width('100%')
    .padding(12)
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: 1, color: $r('app.color.app_divider') })
    .margin({ top: 16 })
  }

  private doSync(direction: string): void {
    this.syncToViewModel();
    if (this.viewModel === null) {
      return;
    }
    this.isSyncing = true;
    this.syncProgress = 0;
    this.syncMessage = '';
    this.resultMessage = '';

    const syncPromise: Promise<SyncResult> = direction === 'upload'
      ? this.viewModel.uploadOnly()
      : direction === 'download'
        ? this.viewModel.downloadOnly()
        : this.viewModel.syncNow();

    syncPromise.then((result: SyncResult) => {
      this.isSyncing = false;
      this.syncProgress = 100;
      this.resultMessage = result.message;
      this.lastSyncTime = this.viewModel !== null ? this.viewModel.lastSyncTime : '';
      if (result.success) {
        promptAction.showToast({ message: result.message });
      }
    }).catch((e: Error) => {
      this.isSyncing = false;
      this.resultMessage = e.message;
    });
  }
}
