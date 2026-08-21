/**
 * CharacterService 角色业务服务
 *
 * 数据源:CharacterRepository(RDB)。
 * 当前角色 ID:CharacterSelectionStore(Preferences)。
 * 头像:CharacterAssetStore(文件系统)。
 * 角色专属世界书:LorebookRepository(可选,用于 character_book 自动导入)。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 校验角色数据
 * - 不直接操作 RdbStore
 * - 不向页面暴露 Repository
 * - 不依赖或持有 CharacterStore(Legacy)
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Character, createCharacter, updateCharacter, validateCharacter, CharacterUpdates } from '../models/Character';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { LorebookRepository } from '../repositories/LorebookRepository';
import { LorebookPosition, createLorebook, createLorebookEntry, Lorebook, LorebookEntry } from '../models/Lorebook';
import { CharacterSelectionStore } from '../storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../storage/CharacterAssetStore';
import { DatabaseError, DatabaseErrorType } from '../models/DatabaseError';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

import {
  parseCharacterJson,
  ParseResult,
  ParsedCharacterCard,
  ParsedCharacterBook,
  ParsedCharacterBookEntry
} from '../parser/CharacterCardJsonParser';
import { writeCharacterToJson, writeCharacterToV2Json } from '../parser/CharacterCardJsonWriter';
import { parsePngCharacterCard, PngParseResult } from '../parser/PngCharacterCardParser';
import {
  exportCharacterToPng,
  generatePlaceholderPng,
  writeCharaCardToPng,
  PngWriteResult
} from '../parser/PngCharacterCardWriter';
import { convertUriToPngBytes, isPngBytes } from '../utils/ImageConverter';

const LOG_TAG: string = 'CharacterService';

/** PNG 导入解析结果 */
export interface PngImportResult {
  result: PngParseResult;
  bytes: ArrayBuffer;
}

export class CharacterService {
  private readonly repository: CharacterRepository;
  private readonly selectionStore: CharacterSelectionStore;
  private readonly assetStore: CharacterAssetStore;
  private readonly lorebookRepository: LorebookRepository | null;
  private initialized: boolean = false;

  constructor(
    repository: CharacterRepository,
    selectionStore: CharacterSelectionStore,
    assetStore: CharacterAssetStore,
    lorebookRepository: LorebookRepository | null = null
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
    this.assetStore = assetStore;
    this.lorebookRepository = lorebookRepository;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.selectionStore.initialize(context);
    this.assetStore.initialize(context);
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('CharacterService not initialized');
    }
  }

  async list(): Promise<Character[]> {
    this.requireInit();
    return await this.repository.list();
  }

  async getById(id: string): Promise<Character | null> {
    this.requireInit();
    return await this.repository.getById(id);
  }

  async create(
    name: string,
    description: string = '',
    personality: string = '',
    scenario: string = '',
    firstMessage: string = '',
    systemPrompt: string = ''
  ): Promise<Character> {
    this.requireInit();
    const sortOrder: number = await this.nextSortOrder();
    const character: Character = createCharacter(
      'char-' + generateUuid(), name, description, personality,
      scenario, firstMessage, systemPrompt,
      '', '', '', '', [], [], '', '', {}, '', '',
      '', sortOrder
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error(error);
    }
    try {
      await this.repository.insert(character);
    } catch (e) {
      // ID 冲突时生成新 UUID 重试一次
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.AlreadyExists) {
        const retryCharacter: Character = cloneCharacterWithNewId(character, 'char-' + generateUuid());
        await this.repository.insert(retryCharacter);
        return retryCharacter;
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService create failed: ' + String(e));
    }
    return character;
  }

  async update(
    id: string,
    updates: CharacterUpdates
  ): Promise<Character> {
    this.requireInit();
    const existing: Character | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('CharacterService update: not found');
    }
    const updated: Character = updateCharacter(existing, updates);
    const error: string | null = validateCharacter(updated);
    if (error !== null) {
      throw new Error(error);
    }
    try {
      await this.repository.update(updated);
    } catch (e) {
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.NotFound) {
        throw new Error('CharacterService update: not found');
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService update failed: ' + String(e));
    }
    return updated;
  }

  /**
   * 更新角色头像。
   *
   * 流程:
   * 1. 备份原 avatarUri
   * 2. saveAvatar 保存新头像(生成带时间戳的新文件名,不覆盖旧文件)
   * 3. update 数据库 avatarUri 字段
   * 4. 数据库更新成功后,清理被替换的旧头像文件
   * 5. 数据库更新失败时,删除新保存的头像文件回滚
   *
   * 失败处理:
   * - saveAvatar 失败:不修改任何内容,旧头像保留
   * - update 失败:删除新保存的头像文件,旧头像仍可用
   * - deleteAvatarByUri 失败:仅记录日志,不影响主流程
   *
   * @param id 角色 ID
   * @param sourceUri 源 PNG 文件 URI(由 picker 返回)
   * @returns 更新后的 Character
   */
  async updateAvatar(id: string, sourceUri: string): Promise<Character> {
    this.requireInit();
    const existing: Character | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('CharacterService updateAvatar: not found');
    }
    const oldAvatarUri: string = existing.avatarUri;
    // 1. 保存新头像
    //    - 先尝试转 PNG 统一格式(支持 JPG/WebP/BMP/GIF 输入)
    //    - 转换失败时回退到原文件直接保存(保留源扩展名)
    let newAvatarUri: string = '';
    try {
      const pngBytes: Uint8Array = await convertUriToPngBytes(sourceUri);
      newAvatarUri = await this.assetStore.savePngAvatarFromBytes(pngBytes, id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'updateAvatar: convert to PNG failed, fallback to raw copy: ' + String(e));
      newAvatarUri = await this.assetStore.saveAvatar(sourceUri, id);
    }
    // 2. 更新数据库
    try {
      const updated: Character = await this.update(id, { avatarUri: newAvatarUri });
      // 3. 数据库更新成功后,清理被替换的旧头像文件
      if (oldAvatarUri.length > 0 && oldAvatarUri !== newAvatarUri) {
        try {
          await this.assetStore.deleteAvatarByUri(oldAvatarUri);
        } catch (e) {
          Logger.warn(LOG_TAG, 'updateAvatar: delete old avatar failed: ' + String(e));
        }
      }
      return updated;
    } catch (e) {
      // 数据库更新失败,删除新保存的头像文件回滚,旧头像仍可用
      try {
        await this.assetStore.deleteAvatarByUri(newAvatarUri);
      } catch (deleteErr) {
        Logger.warn(LOG_TAG, 'updateAvatar: rollback new avatar failed: ' + String(deleteErr));
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService updateAvatar failed: ' + String(e));
    }
  }

  async remove(id: string): Promise<void> {
    this.requireInit();
    const existing: Character | null = await this.repository.getById(id);
    if (existing === null) {
      // 幂等:不存在视为已删除
      return;
    }
    // 1. 删除关联的角色专属世界书(如果存在)
    if (existing.characterBookId.length > 0 && this.lorebookRepository !== null) {
      try {
        await this.lorebookRepository.remove(existing.characterBookId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'remove: character_book delete failed: ' + String(e));
      }
    }
    // 2. 删除 RDB Character
    await this.repository.remove(id);
    // 3. 若是当前角色,清空选择
    const currentId: string | null = await this.selectionStore.getCurrentCharacterId();
    if (currentId === id) {
      await this.selectionStore.clear();
    }
    // 4. 删除头像文件(失败不回滚角色记录)
    try {
      await this.assetStore.deleteAvatar(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'remove: deleteAvatar failed, character record already deleted');
    }
  }

  async setCurrentCharacterId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null) {
      const exists: boolean = await this.repository.exists(id);
      if (!exists) {
        throw new Error('CharacterService setCurrentCharacterId: not found');
      }
    }
    await this.selectionStore.setCurrentCharacterId(id);
  }

  async getCurrentCharacterId(): Promise<string | null> {
    this.requireInit();
    return await this.selectionStore.getCurrentCharacterId();
  }

  async getCurrentCharacter(): Promise<Character | null> {
    this.requireInit();
    const id: string | null = await this.selectionStore.getCurrentCharacterId();
    if (id === null) {
      return null;
    }
    const c: Character | null = await this.repository.getById(id);
    if (c === null) {
      // 选择指向的角色已被删除,清空选择
      await this.selectionStore.clear();
      return null;
    }
    return c;
  }

  // ===== 导入导出 =====

  /**
   * 解析角色卡 JSON(不保存)。
   * 用于导入前预览。
   */
  parseCharacterJson(jsonString: string): ParseResult {
    return parseCharacterJson(jsonString);
  }

  /**
   * 从解析后的角色卡创建并保存 Character。
   * id 冲突时生成新 UUID,不覆盖现有角色。
   * 如果 parsed.characterBook 非空且注入了 LorebookRepository,
   * 自动创建 Lorebook 并链接到 characterBookId。
   */
  async importFromParsed(parsed: ParsedCharacterCard, avatarUri?: string): Promise<Character> {
    this.requireInit();
    const finalAvatarUri: string = avatarUri !== undefined ? avatarUri : parsed.avatarUri;

    // 1. 导入角色专属世界书(如果存在)
    const characterBookId: string = await this.importCharacterBookIfNeeded(parsed);

    // 2. 创建 Character
    const sortOrder: number = await this.nextSortOrder();
    let character: Character = createCharacter(
      'char-' + generateUuid(),
      parsed.name,
      parsed.description,
      parsed.personality,
      parsed.scenario,
      parsed.firstMessage,
      parsed.systemPrompt,
      finalAvatarUri,
      parsed.mesExample,
      parsed.creatorNotes,
      parsed.postHistoryInstructions,
      parsed.alternateGreetings,
      parsed.tags,
      parsed.creator,
      parsed.characterVersion,
      parsed.extensions,
      characterBookId,
      parsed.userName,
      '',
      sortOrder
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error(error);
    }
    try {
      await this.repository.insert(character);
    } catch (e) {
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.AlreadyExists) {
        // ID 冲突,生成新 UUID 重试
        character = cloneCharacterWithNewId(character, 'char-' + generateUuid());
        await this.repository.insert(character);
      } else {
        if (e instanceof Error) {
          throw e;
        }
        throw new Error('CharacterService importFromParsed failed: ' + String(e));
      }
    }
    return character;
  }

  /**
   * 从 JSON 字符串解析并导入角色。
   */
  async importFromJson(jsonString: string): Promise<Character> {
    const result: ParseResult = this.parseCharacterJson(jsonString);
    if (!result.success || result.card === null) {
      throw new Error(result.error !== null ? result.error : '导入失败');
    }
    return await this.importFromParsed(result.card);
  }

  /**
   * 将角色导出为 ArkTavern JSON 字符串(包含 V2 字段)。
   */
  async exportToJson(id: string): Promise<string> {
    this.requireInit();
    const character: Character | null = await this.repository.getById(id);
    if (character === null) {
      throw new Error('CharacterService exportToJson: not found');
    }
    return writeCharacterToJson(character);
  }

  /**
   * 将角色导出为 SillyTavern V2 chara_card JSON 字符串。
   * 保留所有 V2 字段和未知 extensions,导入后导出不丢字段。
   */
  async exportToV2Json(id: string): Promise<string> {
    this.requireInit();
    const character: Character | null = await this.repository.getById(id);
    if (character === null) {
      throw new Error('CharacterService exportToV2Json: not found');
    }
    return writeCharacterToV2Json(character);
  }

  /**
   * 从文件 URI 读取文本内容。
   * 检查文件大小不超过 10MB。
   */
  async readFileContent(uri: string): Promise<string> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size > 10 * 1024 * 1024) {
        fileIo.closeSync(file);
        throw new Error('文件过大,不能超过 10MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const content: string = textDecoder.decodeToString(new Uint8Array(buffer, 0, readLen));
      return content;
    } catch (e) {
      if (e instanceof Error && e.message.includes('文件过大')) {
        throw e;
      }
      Logger.error(LOG_TAG, 'readFileContent failed: ' + String(e));
      throw new Error('读取文件失败');
    }
  }

  /**
   * 将文本内容写入文件 URI。
   */
  async writeFileContent(uri: string, content: string): Promise<void> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      const textEncoder: util.TextEncoder = new util.TextEncoder();
      const buffer: Uint8Array = textEncoder.encodeInto(content);
      fileIo.writeSync(file.fd, buffer.buffer as ArrayBuffer);
      fileIo.closeSync(file);
    } catch (e) {
      Logger.error(LOG_TAG, 'writeFileContent failed: ' + String(e));
      throw new Error('写入文件失败');
    }
  }

  /**
   * 从文件 URI 导入角色。
   */
  async importFromFile(uri: string): Promise<Character> {
    const jsonString: string = await this.readFileContent(uri);
    return await this.importFromJson(jsonString);
  }

  /**
   * 导出角色到文件 URI。
   */
  async exportToFile(id: string, uri: string): Promise<void> {
    const jsonString: string = await this.exportToJson(id);
    await this.writeFileContent(uri, jsonString);
  }

  // ===== V2 / PNG 导出 =====

  /**
   * 导出角色为包含 character_book 的完整 V2 JSON 字符串。
   *
   * 流程:
   * 1. 加载角色
   * 2. 加载角色专属 Lorebook(若 characterBookId 非空)
   * 3. 把 Lorebook 转换为 Tavern Card V2 character_book 结构
   * 4. 调用 JsonWriter 写出 V2 JSON
   *
   * 不包含 id / avatarUri / characterBookId / createdAt / updatedAt
   * 不包含 API Key / Provider 配置 / 聊天记录 / 本地路径
   */
  async exportToV2JsonWithBook(id: string): Promise<string> {
    this.requireInit();
    const character: Character | null = await this.repository.getById(id);
    if (character === null) {
      throw new Error('CharacterService exportToV2JsonWithBook: not found');
    }
    // 基础 V2 JSON(不含 character_book)
    const baseJson: string = writeCharacterToV2Json(character);
    // 加载角色专属 Lorebook
    let characterBookJson: string = '';
    if (character.characterBookId.length > 0 && this.lorebookRepository !== null) {
      try {
        const book: Lorebook | null = await this.lorebookRepository.getById(character.characterBookId);
        if (book !== null) {
          characterBookJson = serializeCharacterBook(book);
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'exportToV2JsonWithBook: load character_book failed: ' + String(e));
      }
    }
    if (characterBookJson.length === 0) {
      return baseJson;
    }
    // 把 character_book 字段注入到 V2 JSON 的 data 对象中
    return injectFieldIntoV2Json(baseJson, 'character_book', characterBookJson);
  }

  /**
   * 读取角色头像 PNG 字节。
   * - 头像不存在:返回 null(调用方决定使用占位 PNG)
   * - 头像存在:返回 PNG 字节
   * - 读取失败:抛错
   */
  async readAvatarBytes(id: string): Promise<Uint8Array | null> {
    this.requireInit();
    const character: Character | null = await this.repository.getById(id);
    if (character === null) {
      throw new Error('CharacterService readAvatarBytes: not found');
    }
    if (character.avatarUri.length === 0) {
      return null;
    }
    const buffer: ArrayBuffer = await this.readFileBytes(character.avatarUri);
    return new Uint8Array(buffer);
  }

  /**
   * 导出角色为 PNG 字节(包含 chara tEXt chunk)。
   *
   * 流程:
   * 1. 生成完整 V2 JSON(含 character_book)
   * 2. 读取头像字节(无头像时使用占位 PNG)
   * 3. 调用 PngCharacterCardWriter 写入 chara tEXt chunk
   *
   * 失败时抛错,不生成损坏文件。
   */
  async exportToPngBytes(id: string): Promise<Uint8Array> {
    this.requireInit();
    const jsonString: string = await this.exportToV2JsonWithBook(id);
    let avatarBytes: Uint8Array | null = null;
    try {
      avatarBytes = await this.readAvatarBytes(id);
      // 校验是否为合法 PNG(PNG 签名:89 50 4E 47 0D 0A 1A 0A)
      // 头像可能是旧数据中的 JPG/WebP,调用 ImageConverter 转 PNG
      if (avatarBytes !== null && !isPngBytes(avatarBytes)) {
        const character: Character | null = await this.repository.getById(id);
        if (character !== null && character.avatarUri.length > 0) {
          avatarBytes = await convertUriToPngBytes(character.avatarUri);
        } else {
          avatarBytes = null;
        }
      }
    } catch (e) {
      // 头像读取/转换失败,使用占位 PNG
      Logger.warn(LOG_TAG, 'exportToPngBytes: read/convert avatar failed, using placeholder: ' + String(e));
      avatarBytes = null;
    }
    const result: PngWriteResult = exportCharacterToPng(avatarBytes, jsonString);
    if (!result.success) {
      throw new Error('PNG 导出失败: ' + result.error);
    }
    return result.bytes;
  }

  /**
   * 将 PNG 字节写入文件 URI(由调用方通过 DocumentViewPicker.save 获取)。
   */
  async writePngToFile(uri: string, bytes: Uint8Array): Promise<void> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      fileIo.closeSync(file);
    } catch (e) {
      Logger.error(LOG_TAG, 'writePngToFile failed: ' + String(e));
      throw new Error('写入 PNG 文件失败');
    }
  }

  /**
   * 导出角色 PNG 到指定文件 URI。
   */
  async exportPngToFile(id: string, uri: string): Promise<void> {
    const bytes: Uint8Array = await this.exportToPngBytes(id);
    await this.writePngToFile(uri, bytes);
  }

  // ===== PNG 导入 =====

  /**
   * 从 URI 读取二进制文件内容。
   */
  async readFileBytes(uri: string): Promise<ArrayBuffer> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size > 50 * 1024 * 1024) {
        fileIo.closeSync(file);
        throw new Error('文件过大,不能超过 50MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      return buffer;
    } catch (e) {
      if (e instanceof Error && e.message.includes('文件过大')) {
        throw e;
      }
      Logger.error(LOG_TAG, 'readFileBytes failed: ' + String(e));
      throw new Error('读取文件失败');
    }
  }

  /**
   * 从 PNG 文件 URI 解析角色卡(不保存)。
   */
  async importPngFromFile(uri: string): Promise<PngImportResult> {
    const bytes: ArrayBuffer = await this.readFileBytes(uri);
    const uint8: Uint8Array = new Uint8Array(bytes);
    const pngResult: PngParseResult = parsePngCharacterCard(uint8);

    if (!pngResult.success) {
      const result: PngImportResult = { result: pngResult, bytes: bytes };
      return result;
    }

    // 复用 CharacterCardJsonParser 解析 JSON
    const jsonResult: ParseResult = parseCharacterJson(pngResult.jsonString);
    if (!jsonResult.success) {
      const errorResult: PngImportResult = {
        result: {
          success: false,
          jsonString: '',
          sourceFormat: pngResult.sourceFormat,
          error: '角色卡 JSON 解析失败: ' + (jsonResult.error !== null ? jsonResult.error : '')
        },
        bytes: bytes
      };
      return errorResult;
    }

    const okResult: PngImportResult = { result: pngResult, bytes: bytes };
    return okResult;
  }

  /**
   * 确认 PNG 导入:保存头像 + 保存角色。
   * 头像保存失败时不创建角色;角色保存失败时回滚头像。
   * 如果 parsed.characterBook 非空且注入了 LorebookRepository,
   * 自动创建 Lorebook 并链接到 characterBookId。
   */
  async confirmPngImport(parsed: ParsedCharacterCard, pngUri: string): Promise<Character> {
    this.requireInit();
    const characterId: string = 'char-' + generateUuid();
    // 1. 保存头像(失败则不创建角色)
    const avatarUri: string = await this.assetStore.saveAvatar(pngUri, characterId);
    // 2. 导入角色专属世界书(如果存在)
    let characterBookId: string = '';
    try {
      characterBookId = await this.importCharacterBookIfNeeded(parsed);
    } catch (e) {
      // character_book 导入失败不阻塞角色导入
      Logger.warn(LOG_TAG, 'confirmPngImport: character_book import failed: ' + String(e));
    }
    // 3. 创建并保存角色
    const sortOrder: number = await this.nextSortOrder();
    const character: Character = createCharacter(
      characterId,
      parsed.name,
      parsed.description,
      parsed.personality,
      parsed.scenario,
      parsed.firstMessage,
      parsed.systemPrompt,
      avatarUri,
      parsed.mesExample,
      parsed.creatorNotes,
      parsed.postHistoryInstructions,
      parsed.alternateGreetings,
      parsed.tags,
      parsed.creator,
      parsed.characterVersion,
      parsed.extensions,
      characterBookId,
      parsed.userName,
      '',
      sortOrder
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      // 回滚:删除已保存的头像
      await this.assetStore.deleteAvatar(characterId);
      throw new Error(error);
    }
    try {
      await this.repository.insert(character);
    } catch (e) {
      // 角色保存失败,回滚头像和 character_book
      await this.assetStore.deleteAvatar(characterId);
      if (characterBookId.length > 0 && this.lorebookRepository !== null) {
        try {
          await this.lorebookRepository.remove(characterBookId);
        } catch (rollbackErr) {
          Logger.warn(LOG_TAG, 'confirmPngImport: rollback character_book failed: ' + String(rollbackErr));
        }
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService confirmPngImport failed: ' + String(e));
    }
    return character;
  }

  // ===== 角色专属世界书导入 =====

  /**
   * 从 ParsedCharacterCard.characterBook 创建 Lorebook 并返回其 ID。
   * 如果 characterBook 为空,或未注入 LorebookRepository,返回空字符串。
   * 失败时抛错(调用方决定是否忽略)。
   */
  private async importCharacterBookIfNeeded(parsed: ParsedCharacterCard): Promise<string> {
    if (parsed.characterBook === null) {
      return '';
    }
    if (this.lorebookRepository === null) {
      Logger.warn(LOG_TAG, 'character_book skipped: lorebookRepository not injected');
      return '';
    }
    const bookName: string = parsed.name + ' · 角色世界书';
    const lorebook: Lorebook = createLorebook(bookName, '从角色卡导入的专属世界书', true);
    const entries: LorebookEntry[] = [];
    for (let i = 0; i < parsed.characterBook.entries.length; i++) {
      const entry: ParsedCharacterBookEntry = parsed.characterBook.entries[i];
      const position: LorebookPosition = mapCharacterBookPosition(entry.position);
      const lorebookEntry: LorebookEntry = createLorebookEntry(
        resolveBookEntryName(entry, i),
        entry.keys,
        entry.secondaryKeys,
        entry.content,
        entry.enabled,
        entry.constant,
        entry.selective,
        position,
        entry.priority
      );
      entries.push(lorebookEntry);
    }
    // 把 entries 加到 lorebook
    const fullLorebook: Lorebook = {
      id: lorebook.id,
      name: lorebook.name,
      description: lorebook.description,
      enabled: lorebook.enabled,
      entries: entries,
      createdAt: lorebook.createdAt,
      updatedAt: lorebook.updatedAt
    };
    await this.lorebookRepository.insert(fullLorebook);
    return lorebook.id;
  }

  /**
   * 计算下一个 sort_order(用于新建/导入角色时分配)。
   * 空表返回 0。
   */
  private async nextSortOrder(): Promise<number> {
    const max: number = await this.repository.getMaxSortOrder();
    return max < 0 ? 0 : max + 1;
  }

  /**
   * 上移角色卡片(与上一条交换 sort_order)。
   * 已是第一条时无操作返回。
   */
  async moveCharacterUp(id: string): Promise<void> {
    this.requireInit();
    const characters: Character[] = await this.repository.list();
    let index: number = -1;
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id === id) {
        index = i;
        break;
      }
    }
    if (index <= 0) {
      return;
    }
    await this.repository.swapSortOrder(id, characters[index - 1].id);
  }

  /**
   * 下移角色卡片(与下一条交换 sort_order)。
   * 已是最后一条时无操作返回。
   */
  async moveCharacterDown(id: string): Promise<void> {
    this.requireInit();
    const characters: Character[] = await this.repository.list();
    let index: number = -1;
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id === id) {
        index = i;
        break;
      }
    }
    if (index < 0 || index >= characters.length - 1) {
      return;
    }
    await this.repository.swapSortOrder(id, characters[index + 1].id);
  }
}

/** PNG 签名校验已迁移到 utils/ImageConverter.ets 的 isPngBytes */

/**
 * 将 character_book 的 position 字符串映射为 LorebookPosition 枚举。
 * 默认 BeforeCharacter。
 */
function mapCharacterBookPosition(position: string): LorebookPosition {
  const lower: string = position.toLowerCase();
  if (lower === 'after_char' || lower === 'after' || lower === 'aftercharacter') {
    return LorebookPosition.AfterCharacter;
  }
  return LorebookPosition.BeforeCharacter;
}

/**
 * 解析世界书条目的显示名称。
 * 优先级:name > comment > 首个关键词 > 兜底"条目 N"。
 * 避免 AI 生成的世界书条目无名称时全部落到"Entry N"。
 */
function resolveBookEntryName(entry: ParsedCharacterBookEntry, index: number): string {
  if (entry.name.trim().length > 0) {
    return entry.name;
  }
  if (entry.comment.trim().length > 0) {
    return entry.comment;
  }
  if (entry.keys.length > 0 && entry.keys[0].trim().length > 0) {
    return entry.keys[0];
  }
  return '条目 ' + String(index + 1);
}

/**
 * 将 LorebookPosition 枚举映射为 Tavern Card V2 character_book 的 position 字符串。
 */
function lorebookPositionToV2String(position: LorebookPosition): string {
  if (position === LorebookPosition.AfterCharacter) {
    return 'after_char';
  }
  return 'before_char';
}

/**
 * 将 Lorebook 序列化为 Tavern Card V2 character_book JSON 字符串。
 *
 * V2 character_book 结构:
 * {
 *   "name": string,
 *   "description": string,
 *   "scan_depth": number,
 *   "token_budget": number,
 *   "recursive_scanning": boolean,
 *   "extensions": {},
 *   "entries": [
 *     {
 *       "keys": string[],
 *       "secondary_keys": string[],
 *       "content": string,
 *       "enabled": boolean,
 *       "constant": boolean,
 *       "selective": boolean,
 *       "position": "before_char" | "after_char",
 *       "priority": number,
 *       "name": string,
 *       "comment": string,
 *       "insertion_order": number,
 *       "case_sensitive": boolean,
 *       "id": number,
 *       "extensions": {}
 *     }
 *   ]
 * }
 */
function serializeCharacterBook(book: Lorebook): string {
  const entriesArr: CharacterBookEntryJson[] = [];
  for (let i = 0; i < book.entries.length; i++) {
    const entry: LorebookEntry = book.entries[i];
    const entryJson: CharacterBookEntryJson = {
      keys: entry.keys,
      secondary_keys: entry.secondaryKeys,
      content: entry.content,
      enabled: entry.enabled,
      constant: entry.constant,
      selective: entry.selective,
      position: lorebookPositionToV2String(entry.position),
      priority: entry.priority,
      insertion_order: i,
      name: entry.name,
      comment: entry.name,
      case_sensitive: false,
      id: i + 1,
      extensions: new EmptyExtensions()
    };
    entriesArr.push(entryJson);
  }
  const bookJson: CharacterBookJson = {
    name: book.name,
    description: book.description,
    scan_depth: 100,
    token_budget: 2048,
    recursive_scanning: false,
    extensions: new EmptyExtensions(),
    entries: entriesArr
  };
  return JSON.stringify(bookJson);
}

/** Tavern Card V2 character_book.entries[] 元素的 JSON 结构 */
interface CharacterBookEntryJson {
  keys: string[];
  secondary_keys: string[];
  content: string;
  enabled: boolean;
  constant: boolean;
  selective: boolean;
  position: string;
  priority: number;
  insertion_order: number;
  name: string;
  comment: string;
  case_sensitive: boolean;
  id: number;
  extensions: EmptyExtensions;
}

/** Tavern Card V2 character_book 的 JSON 结构 */
interface CharacterBookJson {
  name: string;
  description: string;
  scan_depth: number;
  token_budget: number;
  recursive_scanning: boolean;
  extensions: EmptyExtensions;
  entries: CharacterBookEntryJson[];
}

/** 空 extensions 占位对象 */
class EmptyExtensions {
  // 空对象,用于 extensions: {}
}

/**
 * 将一个字段注入到 V2 JSON 字符串的 data 对象中。
 *
 * 简单实现:利用 V2 JSON 结构固定,
 * 找到 `"data": {` 的位置,在其后插入新字段。
 *
 * @param v2Json 原始 V2 JSON 字符串
 * @param fieldName 字段名(如 'character_book')
 * @param fieldValueJson 字段值的 JSON 字符串
 * @returns 注入后的 V2 JSON 字符串
 */
function injectFieldIntoV2Json(v2Json: string, fieldName: string, fieldValueJson: string): string {
  const dataMarker: string = '"data": {';
  const idx: number = v2Json.indexOf(dataMarker);
  if (idx < 0) {
    return v2Json;
  }
  const insertPos: number = idx + dataMarker.length;
  const injection: string = '\n    "' + fieldName + '": ' + fieldValueJson + ',';
  return v2Json.slice(0, insertPos) + injection + v2Json.slice(insertPos);
}

/**
 * 克隆 Character 并替换 id。
 * 用于 ID 冲突时生成新 UUID 重试。
 * ArkTS 不允许 spread 对象字面量,必须显式构造。
 */
function cloneCharacterWithNewId(character: Character, newId: string): Character {
  return {
    id: newId,
    name: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    firstMessage: character.firstMessage,
    systemPrompt: character.systemPrompt,
    avatarUri: character.avatarUri,
    mesExample: character.mesExample,
    creatorNotes: character.creatorNotes,
    postHistoryInstructions: character.postHistoryInstructions,
    alternateGreetings: character.alternateGreetings,
    tags: character.tags,
    creator: character.creator,
    characterVersion: character.characterVersion,
    extensions: character.extensions,
    characterBookId: character.characterBookId,
    userName: character.userName,
    defaultPersonaId: character.defaultPersonaId,
    sortOrder: character.sortOrder,
    createdAt: character.createdAt,
    updatedAt: character.updatedAt
  };
}
