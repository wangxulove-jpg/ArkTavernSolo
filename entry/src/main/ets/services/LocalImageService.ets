/**
 * LocalImageService 本地图片库业务服务
 *
 * 模型(v50,用户定稿):**图片池 + 标签即预设**
 * - 所有图片一个池子,不再分「全局 / 角色专属」(旧 `character_id` 停用)
 * - 每张图:唯一名字(模型用 `![描述](arkimg:名字)` 引用)+ 一段描述
 * - **标签就是普通提示词预设**:把「名字(:描述)」写进预设正文即视为打上该标签;
 *   因此"图片属于哪些标签"由正文**反推**(utils/LocalImageTagText),不存任何关联表
 * - 渲染解析映射 = 全部图片(名字 → 沙箱文件);AI 能看到哪些图由"会话启用了哪些预设"决定
 *
 * 一致性(名字是唯一标识,故库内变更要同步回正文):
 * - 改名 → 把提到它的预设条目一并改名
 * - 改描述 → 一并更新条目描述
 * - 删除图片 → 从提到它的预设正文里移除该条目
 *
 * 不负责:UI、页面路由、ArkUI 相关逻辑。
 */

import {
  LocalImage,
  newLocalImageId,
  createLocalImage,
  isValidImageName,
  isValidImageDescription,
  describeImageNameProblem,
  describeImageDescriptionProblem,
  normalizeImageName,
  normalizeImageDescription
} from '../models/LocalImage';
import { PromptPreset } from '../models/PromptPreset';
import { LocalImageRepository } from '../repositories/LocalImageRepository';
import { LocalImageAssetStore } from '../storage/LocalImageAssetStore';
import { toResolutionMap } from '../utils/LocalImageResolution';
import {
  upsertTagEntry,
  removeTagEntry,
  hasTagEntry
} from '../utils/LocalImageTagText';
import { PromptPresetService } from './PromptPresetService';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';
import { common } from '@kit.AbilityKit';

const LOG_TAG: string = 'LocalImageService';

export class LocalImageService {
  private readonly repository: LocalImageRepository;
  private readonly assetStore: LocalImageAssetStore;
  private readonly presetService: PromptPresetService;

  constructor(
    repository: LocalImageRepository,
    assetStore: LocalImageAssetStore,
    presetService: PromptPresetService
  ) {
    this.repository = repository;
    this.assetStore = assetStore;
    this.presetService = presetService;
  }

  // ===== 查询 =====

  /** 初始化:建沙箱图片目录 */
  async initialize(context: common.Context): Promise<void> {
    this.assetStore.initialize(context);
  }

  /** 全部图片(按名字升序) */
  async listImages(): Promise<LocalImage[]> {
    return await this.repository.listAll();
  }

  /**
   * 全部提示词预设(供图片库页当作"标签"使用)。
   * 读取失败返回空数组(库页降级为"没有标签",不影响图片本身)。
   */
  async listPresets(): Promise<PromptPreset[]> {
    try {
      return await this.presetService.list();
    } catch (e) {
      Logger.warn(LOG_TAG, 'listPresets failed: ' + String(e));
      return [];
    }
  }

  /** 新建一个空正文的标签预设(正文由"把图片分到该标签"时逐行写入) */
  async createTagPreset(name: string): Promise<void> {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      throw new Error('标签名不能为空');
    }
    await this.presetService.create({
      name: trimmed,
      description: '本地图片标签(由「本地图片库」维护条目,可手动编辑)',
      systemPrompt: ''
    });
  }

  /**
   * 名字 → 文件 URI 的解析映射(供聊天渲染层)。
   * 图片池模型:不做任何范围过滤,全部图片都进映射。
   */
  async buildResolutionMap(): Promise<Record<string, string>> {
    try {
      return toResolutionMap(await this.repository.listAll());
    } catch (e) {
      Logger.warn(LOG_TAG, 'buildResolutionMap failed: ' + String(e));
      return {};
    }
  }

  // ===== 图片变更 =====

  /**
   * 导入一张图片:复制文件进沙箱 → 写数据库。
   * @param sourceUri 系统选择器返回的源 URI
   * @param name 用户起的名字(全局唯一)
   * @param description 给模型看的描述(可空)
   */
  async addImage(sourceUri: string, name: string, description: string): Promise<LocalImage> {
    if (!isValidImageName(name)) {
      throw new Error(describeImageNameProblem(name));
    }
    if (!isValidImageDescription(description)) {
      throw new Error(describeImageDescriptionProblem(description));
    }
    const trimmedName: string = name.trim();
    const nameKey: string = normalizeImageName(trimmedName);
    const taken: boolean = await this.repository.nameTaken(nameKey);
    if (taken) {
      throw new Error('已有同名图片:' + trimmedName);
    }

    const id: string = newLocalImageId();
    const fileUri: string = await this.assetStore.saveImage(sourceUri, id);
    const image: LocalImage = createLocalImage({
      id: id,
      name: trimmedName,
      fileUri: fileUri,
      description: description
    });
    try {
      await this.repository.insert(image);
    } catch (e) {
      // 入库失败(如并发重名) → 回收已落盘的文件,避免孤儿文件
      await this.assetStore.deleteByUri(fileUri);
      throw new Error('保存图片记录失败:' + (e as Error).message);
    }
    return image;
  }

  /** 改名(全局唯一);并把提到它的标签预设条目一并改名 */
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
      const taken: boolean = await this.repository.nameTaken(nameKey);
      if (taken) {
        throw new Error('已有同名图片:' + trimmedName);
      }
    }
    await this.repository.updateName(id, trimmedName, nameKey, nowMillis());
    await this.rewritePresetEntries(existing.name, trimmedName, existing.description, false);
  }

  /** 改描述;并把提到它的标签预设条目描述一并更新 */
  async updateImageDescription(id: string, description: string): Promise<void> {
    if (!isValidImageDescription(description)) {
      throw new Error(describeImageDescriptionProblem(description));
    }
    const existing: LocalImage | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('图片不存在或已被删除');
    }
    const normalized: string = normalizeImageDescription(description);
    if (normalized === existing.description) {
      return;
    }
    await this.repository.updateDescription(id, normalized, nowMillis());
    await this.rewritePresetEntries(existing.name, existing.name, normalized, false);
  }

  /** 删除图片(数据库记录 + 沙箱文件 + 从标签预设正文移除该条目) */
  async removeImage(id: string): Promise<void> {
    const existing: LocalImage | null = await this.repository.getById(id);
    if (existing === null) {
      return;
    }
    await this.repository.remove(id);
    await this.assetStore.deleteByUri(existing.fileUri);
    await this.rewritePresetEntries(existing.name, '', '', true);
  }

  // ===== 标签(= 提示词预设正文) =====

  /**
   * 把一张图分到若干标签:在这些预设正文里写入/更新 `- 名字：描述`。
   * 幂等:正文未变化时跳过写入。
   */
  async attachImageToPresets(imageId: string, presetIds: string[]): Promise<void> {
    const image: LocalImage | null = await this.repository.getById(imageId);
    if (image === null) {
      throw new Error('图片不存在或已被删除');
    }
    for (let i = 0; i < presetIds.length; i++) {
      const presetId: string = presetIds[i];
      const preset: PromptPreset | null = await this.presetService.getById(presetId);
      if (preset === null) {
        continue;
      }
      const nextText: string = upsertTagEntry(preset.systemPrompt, image.name, image.description);
      if (nextText === preset.systemPrompt) {
        continue;
      }
      await this.presetService.update(presetId, { systemPrompt: nextText });
    }
  }

  /** 把一张图从若干标签里移出:从这些预设正文里删掉它的条目行 */
  async detachImageFromPresets(imageId: string, presetIds: string[]): Promise<void> {
    const image: LocalImage | null = await this.repository.getById(imageId);
    if (image === null) {
      throw new Error('图片不存在或已被删除');
    }
    for (let i = 0; i < presetIds.length; i++) {
      const presetId: string = presetIds[i];
      const preset: PromptPreset | null = await this.presetService.getById(presetId);
      if (preset === null) {
        continue;
      }
      const nextText: string = removeTagEntry(preset.systemPrompt, image.name);
      if (nextText === preset.systemPrompt) {
        continue;
      }
      await this.presetService.update(presetId, { systemPrompt: nextText });
    }
  }

  // ===== 内部:库内变更 → 同步进"提到这张图的"预设正文 =====

  /**
   * 把图片名/描述的变化同步进所有"提到该名字"的预设正文。
   * @param currentName 当前(旧)名字,用于定位条目行
   * @param nextName 新名字;remove=true 时忽略
   * @param nextDescription 新描述;remove=true 时忽略
   * @param remove true = 从正文移除该条目
   */
  private async rewritePresetEntries(
    currentName: string,
    nextName: string,
    nextDescription: string,
    remove: boolean
  ): Promise<void> {
    let presets: PromptPreset[] = [];
    try {
      presets = await this.presetService.list();
    } catch (e) {
      Logger.warn(LOG_TAG, 'rewritePresetEntries list presets failed: ' + String(e));
      return;
    }
    for (let i = 0; i < presets.length; i++) {
      const preset: PromptPreset = presets[i];
      if (!hasTagEntry(preset.systemPrompt, currentName)) {
        continue;
      }
      const nextText: string = remove
        ? removeTagEntry(preset.systemPrompt, currentName)
        : upsertTagEntry(removeTagEntry(preset.systemPrompt, currentName), nextName, nextDescription);
      if (nextText === preset.systemPrompt) {
        continue;
      }
      try {
        await this.presetService.update(preset.id, { systemPrompt: nextText });
      } catch (e) {
        // 单个预设同步失败不影响其余(库内数据已更新,预设可由用户手动修正)
        Logger.warn(LOG_TAG, 'rewritePresetEntries update failed preset=' + preset.id + ': ' + String(e));
      }
    }
  }
}