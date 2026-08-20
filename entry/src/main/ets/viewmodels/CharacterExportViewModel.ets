/**
 * CharacterExportViewModel 角色导出页面状态管理
 *
 * 职责:
 * - 调用 CharacterService 生成 V2 JSON 字符串或 PNG 字节
 * - 不直接调用系统文件保存器(由页面处理,ViewModel 只负责数据)
 *
 * 不依赖:
 * - ArkUI
 * - 系统文件 picker
 *
 * 字段策略:
 * - V2 JSON 默认包含 character_book(若角色绑定了 Lorebook)
 * - PNG 使用头像或占位图,内嵌 V2 JSON
 * - 不包含 API Key / Provider 配置 / 聊天记录 / 本地路径
 */

import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';
import { sanitizeFileName } from '../parser/CharacterCardJsonWriter';

const LOG_TAG: string = 'CharacterExportViewModel';

/** 导出格式 */
export enum CharacterExportFormat {
  /** Tavern Card V2 JSON */
  V2Json = 'v2Json',
  /** Tavern Card V2 PNG(内嵌 V2 JSON) */
  V2Png = 'v2Png'
}

/** 导出结果 */
export interface CharacterExportResult {
  success: boolean;
  /** 导出格式(JSON 文本 或 PNG 字节) */
  format: CharacterExportFormat;
  /** JSON 字符串(format=V2Json 时有效) */
  jsonString: string;
  /** PNG 字节(format=V2Png 时有效) */
  pngBytes: Uint8Array;
  /** 默认文件名(含扩展名) */
  defaultFileName: string;
  /** 错误信息 */
  error: string;
}

export class CharacterExportViewModel {
  private readonly characterService: CharacterService;

  constructor(characterService: CharacterService) {
    this.characterService = characterService;
  }

  /**
   * 导出角色为 V2 JSON 字符串。
   *
   * @param characterId 角色 ID
   * @param characterName 角色名称(用于生成默认文件名)
   */
  async exportToJson(characterId: string, characterName: string): Promise<CharacterExportResult> {
    try {
      const jsonString: string = await this.characterService.exportToV2JsonWithBook(characterId);
      const baseName: string = stripExtension(sanitizeFileName(characterName));
      return {
        success: true,
        format: CharacterExportFormat.V2Json,
        jsonString: jsonString,
        pngBytes: new Uint8Array(0),
        defaultFileName: baseName + '.json',
        error: ''
      };
    } catch (e) {
      Logger.error(LOG_TAG, 'exportToJson failed: ' + String(e));
      return {
        success: false,
        format: CharacterExportFormat.V2Json,
        jsonString: '',
        pngBytes: new Uint8Array(0),
        defaultFileName: '',
        error: (e as Error).message ?? '导出失败'
      };
    }
  }

  /**
   * 导出角色为 PNG 字节(包含 chara tEXt chunk)。
   *
   * @param characterId 角色 ID
   * @param characterName 角色名称(用于生成默认文件名)
   */
  async exportToPng(characterId: string, characterName: string): Promise<CharacterExportResult> {
    try {
      const pngBytes: Uint8Array = await this.characterService.exportToPngBytes(characterId);
      const baseName: string = stripExtension(sanitizeFileName(characterName));
      return {
        success: true,
        format: CharacterExportFormat.V2Png,
        jsonString: '',
        pngBytes: pngBytes,
        defaultFileName: baseName + '.png',
        error: ''
      };
    } catch (e) {
      Logger.error(LOG_TAG, 'exportToPng failed: ' + String(e));
      return {
        success: false,
        format: CharacterExportFormat.V2Png,
        jsonString: '',
        pngBytes: new Uint8Array(0),
        defaultFileName: '',
        error: (e as Error).message ?? '导出失败'
      };
    }
  }
}

/** 移除文件名末尾的 .json 扩展名(sanitizeFileName 默认追加 .json) */
function stripExtension(fileName: string): string {
  if (fileName.endsWith('.json')) {
    return fileName.substring(0, fileName.length - 5);
  }
  return fileName;
}
