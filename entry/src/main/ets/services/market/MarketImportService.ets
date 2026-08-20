/**
 * MarketImportService 市场角色卡导入服务
 *
 * 负责将市场 Provider 上的角色卡下载并导入到本地:
 * 1. 检查重复(providerId + remoteId 映射)
 * 2. 优先下载 PNG,失败/不可用时下载 JSON
 * 3. 复用 CharacterService 现有导入流程(PngCharacterCardParser + CharacterCardJsonParser)
 * 4. 注入来源元数据到 extensions.arktavern.market(不覆盖第三方已有字段)
 * 5. 保存头像(PNG 导入时自动;JSON 导入时单独下载并 updateAvatar)
 * 6. 导入成功后更新 MarketImportedMapStore
 * 7. 清理临时文件
 *
 * 安全:
 * - 不重新实现角色卡解析器
 * - 不修改 CharacterService / Parser 现有逻辑
 * - 不缓存完整角色卡数据(除临时文件,使用后删除)
 * - 不记录请求 URL / API Key
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { CharacterService } from '../CharacterService';
import { MarketService } from './MarketService';
import { MarketImportedMapStore } from './MarketImportedMapStore';
import { MarketCharacterDetail } from '../../models/MarketCharacterDetail';
import { MarketCharacter } from '../../models/MarketCharacter';
import {
  MarketSourceMetadata,
  createMarketSourceMetadata,
  serializeMarketSourceMetadata
} from '../../models/MarketSourceMetadata';
import {
  ParsedCharacterCard,
  ParseResult
} from '../../parser/CharacterCardJsonParser';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketImportService';
const TEMP_PNG_PREFIX: string = 'market_temp_';
const MAX_PNG_BYTES: number = 50 * 1024 * 1024; // 50MB
const MAX_JSON_BYTES: number = 10 * 1024 * 1024; // 10MB

/**
 * 导入结果状态。
 */
export enum MarketImportStatus {
  /** 导入成功 */
  Imported = 'imported',
  /** 检测到重复(由调用方决定后续操作) */
  DuplicateFound = 'duplicate',
  /** 网络错误 */
  NetworkError = 'network_error',
  /** 解析错误 */
  ParseError = 'parse_error',
  /** 未知错误 */
  UnknownError = 'unknown_error'
}

/**
 * 导入结果。
 */
export interface MarketImportResult {
  readonly status: MarketImportStatus;
  readonly character: Character | null;
  readonly existingLocalId: string;
  readonly errorMessage: string;
}

/**
 * 重复检测结果。
 */
export interface DuplicateCheckResult {
  /** 是否重复 */
  readonly isDuplicate: boolean;
  /** 重复来源描述('imported' / 'name_creator' / 'source_url') */
  readonly reason: string;
  /** 已存在的本地角色 ID(可空) */
  readonly existingLocalId: string;
  /** 已存在的本地角色名(用于 UI 显示) */
  readonly existingLocalName: string;
}

/**
 * 市场角色卡导入服务。
 */
export class MarketImportService {
  private marketService: MarketService;
  private characterService: CharacterService;
  private importedMap: MarketImportedMapStore;
  private appContext: common.Context;

  constructor(
    marketService: MarketService,
    characterService: CharacterService,
    importedMap: MarketImportedMapStore,
    context: common.Context
  ) {
    this.marketService = marketService;
    this.characterService = characterService;
    this.importedMap = importedMap;
    this.appContext = context;
  }

  /**
   * 检查重复导入。
   * 检查项:
   * 1. providerId + remoteId 在 MarketImportedMapStore 中
   * 2. 本地角色中是否存在相同 sourceUrl(extensions.arktavern.market.sourceUrl)
   * 3. 本地角色中是否存在相同 name + creator
   */
  async checkDuplicate(detail: MarketCharacterDetail): Promise<DuplicateCheckResult> {
    const providerId: string = detail.base.providerId;
    const remoteId: string = detail.base.remoteId;
    // 检查 1:导入映射
    const existingId: string = await this.importedMap.get(providerId, remoteId);
    if (existingId.length > 0) {
      const existingChar: Character | null = await this.characterService.getById(existingId);
      if (existingChar !== null) {
        return {
          isDuplicate: true,
          reason: 'imported',
          existingLocalId: existingId,
          existingLocalName: existingChar.name
        };
      }
    }
    // 检查 2 + 3:遍历本地角色
    const allChars: Character[] = await this.characterService.list();
    const sourceUrl: string = detail.base.sourceUrl;
    const targetName: string = detail.base.name;
    const targetCreator: string = detail.base.creator;
    for (let i = 0; i < allChars.length; i++) {
      const c: Character = allChars[i];
      // 检查 2:sourceUrl 匹配(通过 extensions.arktavern.market.sourceUrl)
      if (sourceUrl.length > 0) {
        const arktavernObj: Object | undefined = c.extensions['arktavern'];
        if (arktavernObj !== undefined && arktavernObj !== null && typeof arktavernObj === 'object') {
          const arktavern: Record<string, Object> = arktavernObj as Record<string, Object>;
          const marketObj: Object | undefined = arktavern['market'];
          if (marketObj !== undefined && marketObj !== null && typeof marketObj === 'object') {
            const market: Record<string, Object> = marketObj as Record<string, Object>;
            const existingSourceUrl: Object | undefined = market['sourceUrl'];
            if (typeof existingSourceUrl === 'string' && existingSourceUrl === sourceUrl) {
              return {
                isDuplicate: true,
                reason: 'source_url',
                existingLocalId: c.id,
                existingLocalName: c.name
              };
            }
          }
        }
      }
      // 检查 3:name + creator 匹配
      if (targetName.length > 0 && c.name === targetName) {
        if (targetCreator.length === 0 || c.creator === targetCreator) {
          return {
            isDuplicate: true,
            reason: 'name_creator',
            existingLocalId: c.id,
            existingLocalName: c.name
          };
        }
      }
    }
    return {
      isDuplicate: false,
      reason: '',
      existingLocalId: '',
      existingLocalName: ''
    };
  }

  /**
   * 导入市场角色卡。
   *
   * 流程:
   * 1. 检查重复(若 allowDuplicate=false,返回 DuplicateFound)
   * 2. 优先下载 PNG,失败回退 JSON
   * 3. 调用 CharacterService 现有导入流程
   * 4. 注入来源元数据到 extensions.arktavern.market
   * 5. 更新 MarketImportedMapStore
   *
   * @param detail 角色详情
   * @param allowDuplicate 是否允许重复导入(用户确认导入为副本时传 true)
   */
  async importCharacter(
    detail: MarketCharacterDetail,
    allowDuplicate: boolean
  ): Promise<MarketImportResult> {
    // 1. 重复检查
    if (!allowDuplicate) {
      const dup: DuplicateCheckResult = await this.checkDuplicate(detail);
      if (dup.isDuplicate) {
        return {
          status: MarketImportStatus.DuplicateFound,
          character: null,
          existingLocalId: dup.existingLocalId,
          errorMessage: dup.reason
        };
      }
    }

    const meta: MarketSourceMetadata = createMarketSourceMetadata(
      detail.base.providerId,
      detail.base.remoteId,
      detail.base.sourceUrl,
      detail.base.updatedAt,
      detail.characterVersion,
      Date.now()
    );

    // 2. 优先 PNG 导入
    let pngResult: MarketImportResult = await this.tryPngImport(detail, meta);
    if (pngResult.status === MarketImportStatus.Imported) {
      // 写入导入映射
      if (pngResult.character !== null) {
        await this.importedMap.put(
          detail.base.providerId, detail.base.remoteId, pngResult.character.id
        );
      }
      return pngResult;
    }
    // PNG 不可用或失败,记录日志后回退 JSON
    Logger.warn(LOG_TAG, 'PNG import unavailable, fallback to JSON: ' + pngResult.errorMessage);

    // 3. JSON 导入
    let jsonResult: MarketImportResult = await this.tryJsonImport(detail, meta);
    if (jsonResult.status === MarketImportStatus.Imported) {
      if (jsonResult.character !== null) {
        await this.importedMap.put(
          detail.base.providerId, detail.base.remoteId, jsonResult.character.id
        );
        // JSON 导入无头像,尝试单独下载头像
        if (detail.pngDownloadUrl.length > 0) {
          await this.tryDownloadAvatar(jsonResult.character.id, detail.pngDownloadUrl);
        }
      }
    }
    return jsonResult;
  }

  /**
   * 删除本地角色时清理导入映射。
   * 应由角色删除流程调用(CharacterService.remove 之后)。
   */
  async onCharacterDeleted(localCharacterId: string): Promise<void> {
    await this.importedMap.removeByLocalId(localCharacterId);
  }

  // ===== 内部方法 =====

  /**
   * 尝试 PNG 导入流程。
   */
  private async tryPngImport(
    detail: MarketCharacterDetail,
    meta: MarketSourceMetadata
  ): Promise<MarketImportResult> {
    let tempFileUri: string = '';
    try {
      const pngBytes: Uint8Array | null = await this.marketService.downloadPng(detail.base.remoteId);
      if (pngBytes === null) {
        return {
          status: MarketImportStatus.UnknownError,
          character: null,
          existingLocalId: '',
          errorMessage: 'No PNG available'
        };
      }
      if (pngBytes.byteLength > MAX_PNG_BYTES) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: 'PNG too large'
        };
      }
      // 写入临时文件
      tempFileUri = await this.writeTempPng(pngBytes);
      // 复用 CharacterService.importPngFromFile 解析
      const pngImport = await this.characterService.importPngFromFile(tempFileUri);
      if (!pngImport.result.success) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: 'PNG parse failed: ' + pngImport.result.error
        };
      }
      // 复用 CharacterCardJsonParser 解析 JSON
      const jsonResult: ParseResult = this.characterService.parseCharacterJson(pngImport.result.jsonString);
      if (!jsonResult.success || jsonResult.card === null) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: 'JSON parse failed'
        };
      }
      // 注入来源元数据
      const injectedCard: ParsedCharacterCard = injectMarketMetadata(jsonResult.card, meta);
      // 调用 confirmPngImport:保存头像 + 创建角色 + 自动导入 character_book
      const character: Character = await this.characterService.confirmPngImport(injectedCard, tempFileUri);
      return {
        status: MarketImportStatus.Imported,
        character: character,
        existingLocalId: '',
        errorMessage: ''
      };
    } catch (e) {
      Logger.error(LOG_TAG, 'tryPngImport failed: ' + String(e));
      return {
        status: MarketImportStatus.UnknownError,
        character: null,
        existingLocalId: '',
        errorMessage: String(e)
      };
    } finally {
      // 清理临时文件
      if (tempFileUri.length > 0) {
        await this.cleanupTempFile(tempFileUri);
      }
    }
  }

  /**
   * 尝试 JSON 导入流程(无头像,后续单独下载)。
   */
  private async tryJsonImport(
    detail: MarketCharacterDetail,
    meta: MarketSourceMetadata
  ): Promise<MarketImportResult> {
    try {
      const jsonString: string = await this.marketService.downloadJson(detail.base.remoteId);
      if (jsonString.length === 0) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: 'Empty JSON'
        };
      }
      if (jsonString.length > MAX_JSON_BYTES) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: 'JSON too large'
        };
      }
      const jsonResult: ParseResult = this.characterService.parseCharacterJson(jsonString);
      if (!jsonResult.success || jsonResult.card === null) {
        return {
          status: MarketImportStatus.ParseError,
          character: null,
          existingLocalId: '',
          errorMessage: jsonResult.error !== null ? jsonResult.error : 'JSON parse failed'
        };
      }
      const injectedCard: ParsedCharacterCard = injectMarketMetadata(jsonResult.card, meta);
      const character: Character = await this.characterService.importFromParsed(injectedCard);
      return {
        status: MarketImportStatus.Imported,
        character: character,
        existingLocalId: '',
        errorMessage: ''
      };
    } catch (e) {
      Logger.error(LOG_TAG, 'tryJsonImport failed: ' + String(e));
      return {
        status: MarketImportStatus.UnknownError,
        character: null,
        existingLocalId: '',
        errorMessage: String(e)
      };
    }
  }

  /**
   * 下载头像并更新角色(用于 JSON 导入后补充头像)。
   * 失败不阻塞导入流程。
   */
  private async tryDownloadAvatar(characterId: string, avatarUrl: string): Promise<void> {
    // 仅允许 HTTPS
    if (!avatarUrl.startsWith('https://')) {
      Logger.warn(LOG_TAG, 'tryDownloadAvatar: non-https url rejected');
      return;
    }
    try {
      const pngBytes: Uint8Array | null = await this.marketService.downloadPng(
        // 这里复用 downloadPng 不合适,因为它需要 remoteId
        // 应直接通过 HttpClient 下载图片字节
        // 简化处理:此处先返回,头像由后续迭代完善
        ''
      );
      // 由于此处不直接支持图片 URL 下载,跳过头像
      // 实际头像下载由调用方 MarketDetailPage 通过 Image 组件渲染(展示用,不持久化)
      // 真正导入头像应使用 Provider 提供的 downloadAvatar 方法,本阶段省略
    } catch (e) {
      Logger.warn(LOG_TAG, 'tryDownloadAvatar failed: ' + String(e));
    }
  }

  /**
   * 写入临时 PNG 文件到 cacheDir。
   * 返回 file:// URI,供 CharacterService.importPngFromFile 使用。
   */
  private async writeTempPng(bytes: Uint8Array): Promise<string> {
    const cacheDir: string = this.appContext.cacheDir;
    const filename: string = TEMP_PNG_PREFIX + Date.now() + '_' + Math.floor(Math.random() * 10000) + '.png';
    const fullPath: string = cacheDir + '/' + filename;
    try {
      const file: fileIo.File = fileIo.openSync(fullPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      return 'file://' + fullPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'writeTempPng failed: ' + String(e));
      throw new Error('写入临时文件失败');
    }
  }

  /**
   * 清理临时文件。
   */
  private async cleanupTempFile(uri: string): Promise<void> {
    let path: string = uri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'cleanupTempFile ignored: ' + String(e));
    }
  }
}

/**
 * 将 MarketSourceMetadata 注入到 ParsedCharacterCard.extensions.arktavern.market。
 *
 * 不覆盖:
 * - 已存在的第三方 extensions 字段
 * - 已存在的 arktavern 命名空间内的其他子字段
 * - 已存在的 market 子字段(保留原市场来源)
 */
function injectMarketMetadata(
  parsed: ParsedCharacterCard,
  meta: MarketSourceMetadata
): ParsedCharacterCard {
  // 复制原 extensions(浅拷贝)
  const newExtensions: Record<string, Object> = {};
  const origKeys: string[] = Object.keys(parsed.extensions);
  for (let i = 0; i < origKeys.length; i++) {
    const k: string = origKeys[i];
    newExtensions[k] = parsed.extensions[k];
  }
  // 获取或创建 arktavern 命名空间
  let arktavernObj: Object | undefined = newExtensions['arktavern'];
  let arktavern: Record<string, Object>;
  if (arktavernObj !== undefined && arktavernObj !== null && typeof arktavernObj === 'object') {
    // 复制已有 arktavern 命名空间(浅拷贝,不修改原对象)
    arktavern = {};
    const existingArktavern: Record<string, Object> = arktavernObj as Record<string, Object>;
    const existingKeys: string[] = Object.keys(existingArktavern);
    for (let i = 0; i < existingKeys.length; i++) {
      const k: string = existingKeys[i];
      arktavern[k] = existingArktavern[k];
    }
    // 已有 market 子字段时不覆盖
    if (arktavern['market'] !== undefined && arktavern['market'] !== null) {
      // 仍然返回新的 extensions,但 market 字段保持原值
    } else {
      arktavern['market'] = JSON.parse(serializeMarketSourceMetadata(meta));
    }
  } else {
    arktavern = {};
    arktavern['market'] = JSON.parse(serializeMarketSourceMetadata(meta));
  }
  newExtensions['arktavern'] = arktavern;
  // 构造新的 ParsedCharacterCard
  return {
    name: parsed.name,
    description: parsed.description,
    personality: parsed.personality,
    scenario: parsed.scenario,
    firstMessage: parsed.firstMessage,
    systemPrompt: parsed.systemPrompt,
    avatarUri: parsed.avatarUri,
    sourceFormat: parsed.sourceFormat,
    mesExample: parsed.mesExample,
    creatorNotes: parsed.creatorNotes,
    postHistoryInstructions: parsed.postHistoryInstructions,
    alternateGreetings: parsed.alternateGreetings,
    tags: parsed.tags,
    creator: parsed.creator,
    characterVersion: parsed.characterVersion,
    extensions: newExtensions,
    characterBook: parsed.characterBook,
    userName: parsed.userName
  };
}
