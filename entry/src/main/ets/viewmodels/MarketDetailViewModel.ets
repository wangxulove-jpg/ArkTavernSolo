/**
 * MarketDetailViewModel 市场角色详情 ViewModel
 *
 * 管理角色详情加载、导入流程、重复检测、UI 状态。
 *
 * 核心职责:
 * 1. 加载远程角色详情
 * 2. 触发导入流程(委托 MarketImportService)
 * 3. 处理重复检测弹窗
 * 4. 处理导入结果弹窗(查看角色/新建对话/继续浏览)
 * 5. 详情翻译(中文/原文切换)
 *
 * 不直接:
 * - 调用 network/ 模块(通过 MarketService / MarketTranslationService)
 * - 调用 CharacterService 的方法(由 MarketImportService 内部调用)
 * - 操作文件系统(由 MarketImportService 内部处理)
 */

import { MarketService } from '../services/market/MarketService';
import {
  MarketImportService,
  MarketImportResult,
  MarketImportStatus,
  DuplicateCheckResult
} from '../services/market/MarketImportService';
import { MarketTranslationService } from '../services/market/MarketTranslationService';
import { MarketCharacter } from '../models/MarketCharacter';
import { MarketCharacterDetail } from '../models/MarketCharacterDetail';
import { MarketDetailTranslation } from '../models/MarketTranslation';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MarketDetailViewModel';

@Observed
export class MarketDetailViewModel {
  // ===== 详情状态 =====
  base: MarketCharacter | null = null;
  detail: MarketCharacterDetail | null = null;
  loading: boolean = false;
  errorMessage: string = '';

  // ===== 导入状态 =====
  importing: boolean = false;
  importError: string = '';
  importStatus: MarketImportStatus | null = null;
  importedCharacter: Character | null = null;

  // ===== 重复检测弹窗 =====
  showDuplicateDialog: boolean = false;
  duplicateReason: string = '';
  duplicateExistingName: string = '';
  duplicateExistingLocalId: string = '';

  // ===== 导入成功弹窗 =====
  showImportSuccessDialog: boolean = false;

  // ===== NSFW 警告(详情已加载但用户未确认查看 NSFW 内容) =====
  showNsfwEntryDialog: boolean = false;

  // ===== 翻译状态 =====
  /** 详情翻译结果(null 表示无翻译,UI 显示原文) */
  detailTranslation: MarketDetailTranslation | null = null;
  /** 翻译进行中 */
  translating: boolean = false;
  /** 当前视图:中文(true) / 原文(false)。默认中文。 */
  viewChinese: boolean = true;
  /** 翻译开关是否已开启(由 load 读取偏好) */
  translateEnabled: boolean = false;

  private marketService: MarketService;
  private importService: MarketImportService;
  /** 翻译服务(可选) */
  private translationService: MarketTranslationService | null;
  /** 操作 ID,防止旧请求覆盖新结果 */
  private operationId: number = 0;

  constructor(
    marketService: MarketService,
    importService: MarketImportService,
    translationService: MarketTranslationService | null = null
  ) {
    this.marketService = marketService;
    this.importService = importService;
    this.translationService = translationService;
  }

  // ===== 生命周期 =====

  /**
   * 加载角色详情。
   * @param base 列表项基础信息
   */
  async load(base: MarketCharacter): Promise<void> {
    this.operationId++;
    const opId: number = this.operationId;
    this.base = base;
    this.detail = null;
    this.detailTranslation = null;
    this.translating = false;
    this.viewChinese = true;
    this.loading = true;
    this.errorMessage = '';
    this.importError = '';
    this.importStatus = null;
    this.importedCharacter = null;
    this.showDuplicateDialog = false;
    this.showImportSuccessDialog = false;
    // 读取翻译开关偏好
    if (this.translationService !== null) {
      try {
        this.translateEnabled = await this.translationService.isTranslateEnabled();
      } catch (e) {
        this.translateEnabled = false;
      }
    }
    try {
      const result: MarketCharacterDetail = await this.marketService.getCharacterDetail(base.remoteId);
      if (opId !== this.operationId) {
        return;
      }
      this.detail = result;
      // 若为 NSFW 内容,弹出 NSFW 警告弹窗(不阻塞详情加载,但提示用户)
      if (result.base.nsfw) {
        this.showNsfwEntryDialog = true;
      }
      // 翻译开关已开启且非 NSFW(或 NSFW 已确认)时,自动触发详情翻译
      if (this.translateEnabled && this.translationService !== null) {
        // NSFW 未确认前不发送敏感文本进行翻译
        const canTranslate: boolean = !result.base.nsfw || !this.showNsfwEntryDialog;
        if (canTranslate) {
          void this.translateDetail();
        }
      }
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      this.errorMessage = String(e);
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.loading = false;
      }
    }
  }

  /**
   * 重试加载详情。
   */
  async retry(): Promise<void> {
    if (this.base === null) {
      return;
    }
    await this.load(this.base);
  }

  /**
   * 释放资源,取消进行中的请求。
   */
  dispose(): void {
    this.operationId++;
    if (this.translationService !== null) {
      this.translationService.cancelAll();
    }
  }

  /**
   * 关闭 NSFW 警告弹窗(用户已知晓)。
   * 关闭后若翻译开关已开启,触发详情翻译。
   */
  dismissNsfwEntryDialog(): void {
    this.showNsfwEntryDialog = false;
    // NSFW 确认后,若翻译开关已开启,触发翻译
    if (this.translateEnabled && this.translationService !== null && this.detail !== null) {
      void this.translateDetail();
    }
  }

  // ===== 翻译 =====

  /**
   * 触发详情翻译。
   * 复用列表阶段缓存(若已翻译列表字段,不重新翻译)。
   * 失败时 detailTranslation 保持 null,UI 显示原文。
   */
  async translateDetail(): Promise<void> {
    if (this.translationService === null) {
      return;
    }
    if (this.detail === null) {
      return;
    }
    this.translating = true;
    const opId: number = this.operationId;
    try {
      const result: MarketDetailTranslation | null = await this.translationService.translateDetail(this.detail);
      if (opId !== this.operationId) {
        return;
      }
      if (result !== null) {
        this.detailTranslation = result;
        // 翻译成功后默认切到中文视图
        this.viewChinese = true;
      }
      // 翻译失败时保持 detailTranslation=null,UI 显示原文
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      Logger.warn(LOG_TAG, 'translateDetail failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.translating = false;
      }
    }
  }

  /**
   * 切换中文 / 原文视图。
   */
  toggleLanguage(): void {
    this.viewChinese = !this.viewChinese;
  }

  /**
   * 是否使用中文显示(有翻译且视图为中文)。
   */
  shouldShowChinese(): boolean {
    return this.detailTranslation !== null && this.viewChinese;
  }

  // ===== 导入流程 =====

  /**
   * 开始导入。
   * 1. 先做重复检测
   * 2. 无重复 -> 直接导入
   * 3. 有重复 -> 弹出重复确认弹窗
   */
  async startImport(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    this.importing = true;
    this.importError = '';
    this.importStatus = null;
    try {
      const detail: MarketCharacterDetail = this.detail;
      const dupCheck: DuplicateCheckResult = await this.importService.checkDuplicate(detail);
      if (dupCheck.isDuplicate) {
        this.showDuplicateDialog = true;
        this.duplicateReason = dupCheck.reason;
        this.duplicateExistingName = dupCheck.existingLocalName;
        this.duplicateExistingLocalId = dupCheck.existingLocalId;
        this.importing = false;
        return;
      }
      // 无重复,直接导入
      await this.executeImport(true);
    } catch (e) {
      this.importError = String(e);
      this.importStatus = MarketImportStatus.UnknownError;
      Logger.error(LOG_TAG, 'startImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 用户确认导入为副本(允许重复)。
   */
  async confirmDuplicateImport(): Promise<void> {
    this.showDuplicateDialog = false;
    await this.executeImport(true);
  }

  /**
   * 用户取消重复导入。
   */
  cancelDuplicateImport(): void {
    this.showDuplicateDialog = false;
    this.duplicateReason = '';
    this.duplicateExistingName = '';
    this.duplicateExistingLocalId = '';
  }

  /**
   * 关闭导入成功弹窗。
   */
  dismissImportSuccess(): void {
    this.showImportSuccessDialog = false;
  }

  // ===== 内部方法 =====

  /**
   * 实际执行导入。
   * @param allowDuplicate 是否允许重复
   */
  private async executeImport(allowDuplicate: boolean): Promise<void> {
    if (this.detail === null) {
      return;
    }
    this.importing = true;
    this.importError = '';
    try {
      const result: MarketImportResult = await this.importService.importCharacter(this.detail, allowDuplicate);
      this.importStatus = result.status;
      if (result.status === MarketImportStatus.Imported) {
        this.importedCharacter = result.character;
        this.showImportSuccessDialog = true;
      } else if (result.status === MarketImportStatus.DuplicateFound) {
        // 兜底:理论上 startImport 已检测过,此处若再触发说明并发场景
        this.showDuplicateDialog = true;
        this.duplicateReason = result.errorMessage;
        this.duplicateExistingLocalId = result.existingLocalId;
        this.duplicateExistingName = '';
      } else {
        this.importError = this.formatImportError(result);
        Logger.warn(LOG_TAG, 'import failed status=' + result.status);
      }
    } catch (e) {
      this.importError = String(e);
      this.importStatus = MarketImportStatus.UnknownError;
      Logger.error(LOG_TAG, 'executeImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 格式化导入错误消息。
   * 仅返回运行时错误详情(无前缀),前缀由 UI 通过资源引用显示。
   */
  private formatImportError(result: MarketImportResult): string {
    return result.errorMessage;
  }
}
