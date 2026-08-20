/**
 * ChatArchiveViewModel 聊天归档导入导出视图模型
 *
 * 作为 UI 层与 ChatArchiveService / ChatArchiveImportService 之间的中间层,
 * 负责:
 * - 打开系统文件选择器(保存/读取)
 * - 调用 Service 执行导出/导入
 * - 维护预览数据、导入结果、忙碌状态等 UI 状态
 * - 角色匹配查询
 *
 * 不依赖:
 * - ArkUI 组件(只导出状态数据)
 * - 数据库 / Repository
 *
 * 日志规则:
 * - 不输出消息正文、完整文件路径、完整 SHA-256
 */

import { picker } from '@kit.CoreFileKit';
import { ChatArchiveService } from '../services/ChatArchiveService';
import {
  ChatArchiveImportService,
  ChatArchivePreviewPayload,
  ChatArchiveImportOptions
} from '../services/ChatArchiveImportService';
import {
  ChatArchiveExportStats,
  ChatArchiveImportResult
} from '../parser/ChatArchiveSchema';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatArchiveViewModel';

/**
 * 导出请求参数(由页面组装)。
 */
export interface ChatArchiveExportRequest {
  /** 对话 ID(单对话导出时必填) */
  readonly conversationId: string;
  /** 对话标题(用于默认文件名) */
  readonly conversationTitle: string;
  /** 角色名(用于默认文件名,无角色传空) */
  readonly characterName: string;
}

/**
 * 角色全部对话导出请求参数。
 */
export interface ChatArchiveCharacterExportRequest {
  readonly characterId: string;
  readonly characterName: string;
}

/**
 * 导入进度阶段。
 */
export type ChatArchiveImportStage =
  | 'idle'
  | 'reading'
  | 'validating'
  | 'analyzing'
  | 'writing'
  | 'done'
  | 'error';

/** 文件选择结果 */
export interface PickedFile {
  readonly uri: string;
  readonly name: string;
}

@Observed
export class ChatArchiveViewModel {
  /** 是否忙碌(导出/导入进行中) */
  isBusy: boolean = false;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';
  /** 最近一次导出统计(成功后设置) */
  lastExportStats: ChatArchiveExportStats | null = null;
  /** 最近一次导入预览(读取并校验通过后设置) */
  previewPayload: ChatArchivePreviewPayload | null = null;
  /** 最近一次导入结果(写入完成后设置) */
  importResult: ChatArchiveImportResult | null = null;
  /** 导入阶段(用于进度提示) */
  importStage: ChatArchiveImportStage = 'idle';
  /** 匹配到的角色列表(预览后查询) */
  matchedCharacters: Character[] = [];
  /** 全部角色列表(手动选择用) */
  allCharacters: Character[] = [];
  /** 用户选择的目标角色 ID(空表示不绑定角色) */
  selectedCharacterId: string = '';
  /** 是否强制导入(用户在重复提示中选择"仍然导入") */
  forceImport: boolean = false;

  private readonly archiveService: ChatArchiveService;
  private readonly importService: ChatArchiveImportService;
  /** 当前文件 URI(导入流程中暂存) */
  private pendingFileUri: string = '';
  /** 当前文件名(导入流程中暂存) */
  private pendingFileName: string = '';

  constructor(
    archiveService: ChatArchiveService,
    importService: ChatArchiveImportService
  ) {
    this.archiveService = archiveService;
    this.importService = importService;
  }

  // ===== 导出 =====

  /**
   * 导出当前对话:
   * 1. 打开系统保存选择器(预填默认文件名)
   * 2. 调用 Service 写入文件
   * 3. 更新 lastExportStats
   *
   * 用户取消时不设置错误。
   */
  async exportCurrentConversation(request: ChatArchiveExportRequest): Promise<boolean> {
    if (this.isBusy) {
      return false;
    }
    this.isBusy = true;
    this.errorMessage = '';
    this.lastExportStats = null;
    try {
      const defaultName: string = ChatArchiveService.generateFileName(
        request.characterName, request.conversationTitle
      );
      const targetUri: string | null = await this.openSavePicker(defaultName);
      if (targetUri === null) {
        // 用户取消
        this.isBusy = false;
        return false;
      }
      const stats: ChatArchiveExportStats = await this.archiveService.exportConversation(
        request.conversationId, targetUri
      );
      this.lastExportStats = stats;
      this.isBusy = false;
      return true;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '导出失败';
      Logger.error(LOG_TAG, 'exportCurrentConversation failed: ' + this.errorMessage);
      this.isBusy = false;
      return false;
    }
  }

  /**
   * 导出角色全部对话:
   * 1. 打开系统保存选择器
   * 2. 调用 Service 写入文件
   */
  async exportCharacterConversations(request: ChatArchiveCharacterExportRequest): Promise<boolean> {
    if (this.isBusy) {
      return false;
    }
    this.isBusy = true;
    this.errorMessage = '';
    this.lastExportStats = null;
    try {
      const defaultName: string = ChatArchiveService.generateCharacterFileName(
        request.characterName
      );
      const targetUri: string | null = await this.openSavePicker(defaultName);
      if (targetUri === null) {
        this.isBusy = false;
        return false;
      }
      const stats: ChatArchiveExportStats = await this.archiveService.exportCharacterConversations(
        request.characterId, targetUri
      );
      this.lastExportStats = stats;
      this.isBusy = false;
      return true;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '导出失败';
      Logger.error(LOG_TAG, 'exportCharacterConversations failed: ' + this.errorMessage);
      this.isBusy = false;
      return false;
    }
  }

  // ===== 导入 =====

  /**
   * 启动导入流程:
   * 1. 打开系统文件选择器
   * 2. 读取并校验文件
   * 3. 生成预览
   * 4. 查询匹配角色
   *
   * 成功后 previewPayload / matchedCharacters / allCharacters 已就绪,
   * UI 显示预览页面,用户确认后调用 confirmImport。
   *
   * @param currentCharacterId 当前角色 ID(用于匹配判断,可空)
   * @returns 是否成功生成预览(false 表示用户取消或出错)
   */
  async startImportFlow(currentCharacterId: string): Promise<boolean> {
    if (this.isBusy) {
      return false;
    }
    this.isBusy = true;
    this.errorMessage = '';
    this.previewPayload = null;
    this.importResult = null;
    this.matchedCharacters = [];
    this.allCharacters = [];
    this.selectedCharacterId = '';
    this.forceImport = false;
    this.importStage = 'reading';

    try {
      const picked: PickedFile | null = await this.openFilePicker();
      if (picked === null) {
        // 用户取消
        this.isBusy = false;
        this.importStage = 'idle';
        return false;
      }
      this.pendingFileUri = picked.uri;
      this.pendingFileName = picked.name;

      this.importStage = 'validating';
      const payload: ChatArchivePreviewPayload = await this.importService.buildPreview(
        picked.uri, picked.name, currentCharacterId
      );
      this.previewPayload = payload;

      this.importStage = 'analyzing';
      // 查询匹配角色
      const matched: Character[] = await this.importService.findMatchingCharacters(
        payload.stats.sourceCharacterId, payload.stats.sourceCharacterName
      );
      this.matchedCharacters = matched;
      // 查询全部角色(供手动选择)
      this.allCharacters = await this.importService.listAllCharacters();
      // 默认选中匹配的第一个角色,或当前角色
      if (matched.length > 0) {
        this.selectedCharacterId = matched[0].id;
      } else if (currentCharacterId.length > 0) {
        this.selectedCharacterId = currentCharacterId;
      }

      this.importStage = 'idle';
      this.isBusy = false;
      return true;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '读取文件失败';
      Logger.error(LOG_TAG, 'startImportFlow failed: ' + this.errorMessage);
      this.importStage = 'error';
      this.isBusy = false;
      return false;
    }
  }

  /**
   * 确认导入:将预览数据写入数据库。
   * 使用当前 selectedCharacterId 和 forceImport。
   */
  async confirmImport(): Promise<boolean> {
    if (this.isBusy) {
      return false;
    }
    if (this.previewPayload === null) {
      this.errorMessage = '没有可导入的预览数据';
      return false;
    }
    this.isBusy = true;
    this.errorMessage = '';
    this.importResult = null;
    this.importStage = 'writing';

    try {
      const options: ChatArchiveImportOptions = {
        targetCharacterId: this.selectedCharacterId,
        fileUri: this.pendingFileUri,
        fileName: this.pendingFileName,
        forceImport: this.forceImport
      };
      const result: ChatArchiveImportResult = await this.importService.performImport(
        this.previewPayload, options
      );
      this.importResult = result;
      this.importStage = 'done';
      this.isBusy = false;
      return true;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '导入失败';
      Logger.error(LOG_TAG, 'confirmImport failed: ' + this.errorMessage);
      this.importStage = 'error';
      this.isBusy = false;
      return false;
    }
  }

  /**
   * 取消导入:清空预览状态。
   */
  cancelImport(): void {
    this.previewPayload = null;
    this.matchedCharacters = [];
    this.allCharacters = [];
    this.selectedCharacterId = '';
    this.forceImport = false;
    this.pendingFileUri = '';
    this.pendingFileName = '';
    this.importStage = 'idle';
    this.errorMessage = '';
  }

  /**
   * 重置全部状态(导出/导入完成后调用)。
   */
  resetState(): void {
    this.isBusy = false;
    this.errorMessage = '';
    this.lastExportStats = null;
    this.previewPayload = null;
    this.importResult = null;
    this.matchedCharacters = [];
    this.allCharacters = [];
    this.selectedCharacterId = '';
    this.forceImport = false;
    this.pendingFileUri = '';
    this.pendingFileName = '';
    this.importStage = 'idle';
  }

  // ===== 内部:文件选择器 =====

  /**
   * 打开系统保存选择器,返回文件 URI。
   * 用户取消返回 null。
   */
  private async openSavePicker(defaultFileName: string): Promise<string | null> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [defaultFileName];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return null;
      }
      return uris[0];
    } catch (e) {
      Logger.warn(LOG_TAG, 'openSavePicker cancelled or failed: ' + String(e));
      return null;
    }
  }

  /**
   * 打开系统文件选择器,返回 {uri, name}。
   * 用户取消返回 null。
   */
  private async openFilePicker(): Promise<PickedFile | null> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return null;
      }
      const uri: string = uris[0];
      // 从 URI 中提取文件名(最后一段)
      const name: string = this.extractFileName(uri);
      const result: PickedFile = { uri: uri, name: name };
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'openFilePicker cancelled or failed: ' + String(e));
      return null;
    }
  }

  /**
   * 从文件 URI 提取显示用文件名。
   */
  private extractFileName(uri: string): string {
    const lastSlash: number = uri.lastIndexOf('/');
    if (lastSlash < 0 || lastSlash >= uri.length - 1) {
      return 'unknown.arktchat.json';
    }
    const name: string = uri.substring(lastSlash + 1);
    // URL 解码(部分 URI 包含 % 编码)
    try {
      return decodeURIComponent(name);
    } catch (e) {
      return name;
    }
  }
}
