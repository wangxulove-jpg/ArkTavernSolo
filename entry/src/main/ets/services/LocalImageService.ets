/**
 * LocalImageService 本地图片库业务服务
 *
 * 职责:
 * - 图片导入/改名/改作用域/删除(文件 + 数据库记录 + 受管预设三者同步)
 * - 名字 → 本地文件 URI 的解析映射(全局先铺,角色专属覆盖),供聊天渲染层使用
 * - 受管「本地图片清单」预设的对账(syncManagedPresets):
 *   按作用域自动创建/更新/删除预设,并强制 位置=末尾、作用域=对应范围、加入已选
 *
 * 单一数据源:图片库表。受管预设的正文是**派生产物** ——
 * 每次库变更后由本服务重写,另在应用启动 / 打开预设页时对账自愈,避免双份状态漂移。
 *
 * 不负责:UI、页面路由、ArkUI 相关逻辑。
 */

import {
  LocalImage,
  newLocalImageId,
  createLocalImage,
  isValidImageName,
  describeImageNameProblem,
  normalizeImageName
} from '../models/LocalImage';
import {
  PromptPreset,
  PresetScope,
  DEFAULT_PRESET_SCOPE,
  MANAGED_IMAGE_GLOBAL_PRESET_ID,
  managedImageCharacterPresetId,
  isManagedImagePresetId
} from '../models/PromptPreset';
import { LocalImageRepository } from '../repositories/LocalImageRepository';
import { LocalImageAssetStore } from '../storage/LocalImageAssetStore';
import {
  buildLocalImageSystemPrompt,
  buildLocalImagePresetName,
  buildLocalImagePresetDescription
} from './LocalImagePromptComposer';
import { PromptPresetService } from './PromptPresetService';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';
import { common } from '@kit.AbilityKit';

const LOG_TAG: string = 'LocalImageService';

/** 角色名解析(角色卡可能已被删除 → 返回空串) */
export type CharacterNameResolver = (characterId: string) => Promise<string>;

/** 作用域展示名(受管预设标题与清单标题用) */
const GLOBAL_SCOPE_LABEL: string = '全局';
const MISSING_CHARACTER_LABEL: string = '角色已删除';

export class LocalImageService {
  private readonly repository: LocalImageRepository;
  private readonly assetStore: LocalImageAssetStore;
  private readonly presetService: PromptPresetService;
  private readonly resolveCharacterName: CharacterNameResolver;

  constructor(
    repository: LocalImageRepository,
    assetStore: LocalImageAssetStore,
    presetService: PromptPresetService,
    resolveCharacterName: CharacterNameResolver
  ) {
    this.repository = repository;
    this.assetStore = assetStore;
    this.presetService = presetService;
    this.resolveCharacterName = resolveCharacterName;
  }

  // ===== 查询 =====

  /**
   * 初始化:建沙箱图片目录 + 启动时对账一次受管预设(自愈,防双份状态漂移)。
   */
  async initialize(context: common.Context): Promise<void> {
    this.assetStore.initialize(context);
    try {
      await this.syncManagedPresets();
    } catch (e) {
      Logger.warn(LOG_TAG, 'initialize syncManagedPresets failed: ' + String(e));
    }
  }

  /** 全部图片(按作用域 + 名字稳定排序) */
  async listImages(): Promise<LocalImage[]> {
    return await this.repository.listAll();
  }

  /** 某作用域的图片('' = 全局) */
  async listByScope(characterId: string): Promise<LocalImage[]> {
    return await this.repository.listByCharacter(characterId);
  }

  /** 有专属图片的角色 id 列表 */
  async listScopeCharacterIds(): Promise<string[]> {
    return await this.repository.listCharacterIdsWithImages();
  }

  /**
   * 名字 → 文件 URI 的解析映射(供聊天渲染层)。
   * 键为归一化名字(nameKey),与模型输出做大小写不敏感匹配。
   * 同名冲突时**角色专属覆盖全局**。
   *
   * @param characterId 当前角色卡 id(null = 只能用全局图)
   */
  async buildResolutionMap(characterId: string | null): Promise<Record<string, string>> {
    const map: Record<string, string> = {};
    try {
      const globalImages: LocalImage[] = await this.repository.listByCharacter('');
      for (let i = 0; i < globalImages.length; i++) {
        map[globalImages[i].nameKey] = globalImages[i].fileUri;
      }
      if (characterId !== null && characterId.length > 0) {
        const ownImages: LocalImage[] = await this.repository.listByCharacter(characterId);
        for (let i = 0; i < ownImages.length; i++) {
          map[ownImages[i].nameKey] = ownImages[i].fileUri;
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'buildResolutionMap failed: ' + String(e));
    }
    return map;
  }

  // ===== 变更(每次变更后自动对账受管预设) =====

  /**
   * 导入一张图片:复制文件进沙箱 → 写数据库 → 对账预设。
   * @param sourceUri 系统选择器返回的源 URI
   * @param name 用户起的名字
   * @param characterId '' = 全局;非空 = 该角色专属
   */
  async addImage(sourceUri: string, name: string, characterId: string): Promise<LocalImage> {
    if (!isValidImageName(name)) {
      throw new Error(describeImageNameProblem(name));
    }
    const trimmedName: string = name.trim();
    const nameKey: string = normalizeImageName(trimmedName);
    const taken: boolean = await this.repository.nameTaken(characterId, nameKey);
    if (taken) {
      throw new Error('该作用域下已有同名图片:' + trimmedName);
    }

    const id: string = newLocalImageId();
    const fileUri: string = await this.assetStore.saveImage(sourceUri, id);
    const image: LocalImage = createLocalImage({
      id: id,
      name: trimmedName,
      fileUri: fileUri,
      characterId: characterId
    });
    try {
      await this.repository.insert(image);
    } catch (e) {
      // 入库失败(如并发重名) → 回收已落盘的文件,避免孤儿文件
      await this.assetStore.deleteByUri(fileUri);
      throw new Error('保存图片记录失败:' + (e as Error).message);
    }
    await this.syncManagedPresetsQuietly();
    return image;
  }

  /** 改名(同一作用域内不可重名) */
  async renameImage(id: string, name: string): Promise<void> {
    if (!isValidImageName(name)) {
      throw new Error(describeImageNameProblem(name));
    }
    const existing: LocalImage | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('图片不存在或已被删除');
    }
    const trimmedName: string = name.trim();
    const nameKey: string = normalizeImageName(trimmedName);
    if (nameKey !== existing.nameKey) {
      const taken: boolean = await this.repository.nameTaken(existing.characterId, nameKey);
      if (taken) {
        throw new Error('该作用域下已有同名图片:' + trimmedName);
      }
    }
    await this.repository.updateName(id, trimmedName, nameKey, nowMillis());
    await this.syncManagedPresetsQuietly();
  }

  /** 改作用域('' = 全局) */
  async changeScope(id: string, characterId: string): Promise<void> {
    const existing: LocalImage | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('图片不存在或已被删除');
    }
    if (existing.characterId === characterId) {
      return;
    }
    const taken: boolean = await this.repository.nameTaken(characterId, existing.nameKey);
    if (taken) {
      throw new Error('目标作用域下已有同名图片:' + existing.name);
    }
    await this.repository.updateCharacter(id, characterId, nowMillis());
    await this.syncManagedPresetsQuietly();
  }

  /** 删除图片(数据库记录 + 沙箱文件) */
  async removeImage(id: string): Promise<void> {
    const existing: LocalImage | null = await this.repository.getById(id);
    if (existing === null) {
      return;
    }
    await this.repository.remove(id);
    await this.assetStore.deleteByUri(existing.fileUri);
    await this.syncManagedPresetsQuietly();
  }

  // ===== 受管预设对账 =====

  /**
   * 按图片库现状对账受管「本地图片清单」预设。
   *
   * 目标集合 = 有图的每个作用域(全局 + 每个有专属图的角色)。
   * 对每个目标:不存在则创建、正文不一致则重写;并强制 位置=末尾 / 作用域=对应范围 / 加入已选。
   * 库里已无图的受管预设 → 删除。
   *
   * 幂等:重复调用不产生额外写入(正文一致时跳过 update)。
   */
  async syncManagedPresets(): Promise<void> {
    const images: LocalImage[] = await this.repository.listAll();
    const globalImages: LocalImage[] = [];
    const ownImages: Record<string, LocalImage[]> = {};
    const ownCharIds: string[] = [];
    for (let i = 0; i < images.length; i++) {
      const img: LocalImage = images[i];
      if (img.characterId.length === 0) {
        globalImages.push(img);
        continue;
      }
      const bucket: LocalImage[] | undefined = ownImages[img.characterId];
      if (bucket === undefined) {
        ownImages[img.characterId] = [img];
        ownCharIds.push(img.characterId);
      } else {
        bucket.push(img);
      }
    }

    const existingManaged: PromptPreset[] = [];
    try {
      const all: PromptPreset[] = await this.presetService.list();
      for (let i = 0; i < all.length; i++) {
        if (isManagedImagePresetId(all[i].id)) {
          existingManaged.push(all[i]);
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'syncManagedPresets list presets failed: ' + String(e));
      return;
    }

    const wantedIds: string[] = [];

    if (globalImages.length > 0) {
      wantedIds.push(MANAGED_IMAGE_GLOBAL_PRESET_ID);
      await this.upsertManagedPreset(
        MANAGED_IMAGE_GLOBAL_PRESET_ID,
        DEFAULT_PRESET_SCOPE,
        GLOBAL_SCOPE_LABEL,
        globalImages,
        existingManaged
      );
    }

    for (let i = 0; i < ownCharIds.length; i++) {
      const characterId: string = ownCharIds[i];
      const presetId: string = managedImageCharacterPresetId(characterId);
      wantedIds.push(presetId);
      const label: string = await this.resolveScopeLabel(characterId);
      const scope: PresetScope = { kind: 'character', characterId: characterId };
      await this.upsertManagedPreset(presetId, scope, label, ownImages[characterId], existingManaged);
    }

    // 清理多余受管预设(库里已无图的)
    for (let i = 0; i < existingManaged.length; i++) {
      const preset: PromptPreset = existingManaged[i];
      if (wantedIds.indexOf(preset.id) >= 0) {
        continue;
      }
      try {
        await this.presetService.remove(preset.id);
      } catch (e) {
        Logger.warn(LOG_TAG, 'syncManagedPresets remove stale failed: ' + String(e));
      }
    }
  }

  /** 单个受管预设的创建/更新 + 位置/作用域/已选强制 */
  private async upsertManagedPreset(
    id: string,
    scope: PresetScope,
    label: string,
    images: LocalImage[],
    existingManaged: PromptPreset[]
  ): Promise<void> {
    const body: string = buildLocalImageSystemPrompt(images, label);
    if (body.length === 0) {
      return;
    }
    const name: string = buildLocalImagePresetName(label);
    const description: string = buildLocalImagePresetDescription(images.length);

    let current: PromptPreset | null = null;
    for (let i = 0; i < existingManaged.length; i++) {
      if (existingManaged[i].id === id) {
        current = existingManaged[i];
        break;
      }
    }

    try {
      if (current === null) {
        await this.presetService.create({
          id: id,
          name: name,
          description: description,
          systemPrompt: body
        });
      } else if (current.systemPrompt !== body ||
        current.name !== name ||
        current.description !== description) {
        await this.presetService.update(id, {
          name: name,
          description: description,
          systemPrompt: body
        });
      }
      // 位置固定在末尾(清单变化不影响它前面的缓存前缀)
      await this.presetService.setPresetPosition(id, 'tail');
      await this.presetService.setPresetScope(id, scope);
      // 保证启用(用户手动取消后会被自动回选,能力不静默失效)
      await this.presetService.addSelectedPresetId(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'upsertManagedPreset failed id=' + id + ': ' + String(e));
    }
  }

  /** 解析作用域展示名(角色缺失时给明确标识) */
  private async resolveScopeLabel(characterId: string): Promise<string> {
    try {
      const name: string = await this.resolveCharacterName(characterId);
      if (name.length > 0) {
        return name;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'resolveScopeLabel failed: ' + String(e));
    }
    return MISSING_CHARACTER_LABEL;
  }

  /** 对账失败不影响主流程(仅记日志) */
  private async syncManagedPresetsQuietly(): Promise<void> {
    try {
      await this.syncManagedPresets();
    } catch (e) {
      Logger.warn(LOG_TAG, 'syncManagedPresetsQuietly failed: ' + String(e));
    }
  }
}