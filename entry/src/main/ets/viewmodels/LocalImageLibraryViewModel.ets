/**
 * LocalImageLibraryViewModel 本地图片库页面状态管理
 *
 * 页面与 LocalImageService 之间的唯一桥梁,不直接依赖 Repository / DbHelper / Preferences。
 *
 * 模型(v50):
 * - **所有图片一个池子**(不再分全局/角色),页面用**标签**分组与筛选
 * - **标签就是普通提示词预设**:预设正文里出现某张图的名字 ⇒ 该图属于该标签(由正文反推)
 */

import {
  LocalImage,
  isValidImageName,
  isValidImageDescription,
  normalizeImageName,
  describeImageNameProblem,
  describeImageDescriptionProblem
} from '../models/LocalImage';
import { PromptPreset } from '../models/PromptPreset';
import { LocalImageService } from '../services/LocalImageService';
import { listTagEntryNames } from '../utils/LocalImageTagText';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LocalImageLibraryViewModel';

/** 筛选:全部图片 */
export const IMAGE_FILTER_ALL: string = '';
/** 筛选:未分类(没被任何预设提到) */
export const IMAGE_FILTER_NONE: string = '__none__';

/** 标签选项(= 一个可当标签用的提示词预设) */
export interface LocalImageTagOption {
  readonly id: string;
  readonly name: string;
  /** 当前被多少张图提到(筛选芯片与"未使用"判断) */
  readonly imageCount: number;
}

/** 展示用条目 */
export interface LocalImageEntry {
  readonly image: LocalImage;
  /** 命中的标签 id 与名字(由预设正文反推) */
  readonly tagIds: string[];
  readonly tagNames: string[];
}

/** 按 id 找标签选项(找不到返回 null) */
function findOption(options: LocalImageTagOption[], id: string): LocalImageTagOption | null {
  for (let i = 0; i < options.length; i++) {
    if (options[i].id === id) {
      return options[i];
    }
  }
  return null;
}

@Observed
export class LocalImageLibraryViewModel {
  /** 展示用条目(图片 + 反推出的标签) */
  entries: LocalImageEntry[] = [];
  /** 全部预设(都可当标签用) */
  tagOptions: LocalImageTagOption[] = [];
  /** 至少被一张图提到的标签(顶部筛选芯片) */
  usedTagOptions: LocalImageTagOption[] = [];
  /** 当前筛选(IMAGE_FILTER_ALL / IMAGE_FILTER_NONE / 预设 id) */
  activeFilter: string = IMAGE_FILTER_ALL;
  /** 列表数据版本(每次刷新自增,ForEach key 用) */
  version: number = 0;

  isLoading: boolean = false;
  isOperating: boolean = false;
  errorMessage: string = '';
  successMessage: string = '';
  showDeleteConfirm: boolean = false;
  pendingDeleteId: string = '';

  private readonly imageService: LocalImageService;
  private disposed: boolean = false;

  constructor(imageService: LocalImageService) {
    this.imageService = imageService;
  }

  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.refresh();
  }

  /** 重新加载图片池与预设,反推每张图的标签 */
  async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const images: LocalImage[] = await this.imageService.listImages();
      const presets: PromptPreset[] = await this.imageService.listPresets();

      // 预设 id → 正文条目名(归一化,做大小写不敏感匹配)
      const entryNamesByPreset: Record<string, string[]> = {};
      for (let i = 0; i < presets.length; i++) {
        const names: string[] = [];
        const raw: string[] = listTagEntryNames(presets[i].systemPrompt);
        for (let j = 0; j < raw.length; j++) {
          names.push(normalizeImageName(raw[j]));
        }
        entryNamesByPreset[presets[i].id] = names;
      }

      const entries: LocalImageEntry[] = [];
      const countById: Record<string, number> = {};
      for (let i = 0; i < images.length; i++) {
        const image: LocalImage = images[i];
        const tagIds: string[] = [];
        const tagNames: string[] = [];
        for (let j = 0; j < presets.length; j++) {
          const preset: PromptPreset = presets[j];
          const names: string[] | undefined = entryNamesByPreset[preset.id];
          if (names === undefined || names.indexOf(image.nameKey) < 0) {
            continue;
          }
          tagIds.push(preset.id);
          tagNames.push(preset.name);
          const current: number | undefined = countById[preset.id];
          countById[preset.id] = (current === undefined ? 0 : current) + 1;
        }
        entries.push({ image: image, tagIds: tagIds, tagNames: tagNames });
      }

      const options: LocalImageTagOption[] = [];
      for (let i = 0; i < presets.length; i++) {
        const count: number | undefined = countById[presets[i].id];
        options.push({
          id: presets[i].id,
          name: presets[i].name,
          imageCount: count === undefined ? 0 : count
        });
      }

      // 当前筛选的标签若已被删除 → 回退到「全部」
      if (this.activeFilter !== IMAGE_FILTER_ALL && this.activeFilter !== IMAGE_FILTER_NONE
        && findOption(options, this.activeFilter) === null) {
        this.activeFilter = IMAGE_FILTER_ALL;
      }

      this.tagOptions = options;
      this.usedTagOptions = options.filter((option: LocalImageTagOption): boolean => option.imageCount > 0);
      this.entries = entries;
      this.version = this.version + 1;
    } catch (e) {
      this.errorMessage = '加载本地图片库失败';
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /** 切换筛选(全部 / 未分类 / 某标签) */
  setFilter(filter: string): void {
    if (this.disposed) {
      return;
    }
    this.activeFilter = filter;
  }

  /** 当前筛选下的条目 */
  filteredEntries(): LocalImageEntry[] {
    if (this.activeFilter === IMAGE_FILTER_ALL) {
      return this.entries;
    }
    if (this.activeFilter === IMAGE_FILTER_NONE) {
      return this.entries.filter((entry: LocalImageEntry): boolean => entry.tagIds.length === 0);
    }
    const tagId: string = this.activeFilter;
    return this.entries.filter((entry: LocalImageEntry): boolean => entry.tagIds.indexOf(tagId) >= 0);
  }

  /** 未分类图片张数 */
  uncategorizedCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].tagIds.length === 0) {
        count = count + 1;
      }
    }
    return count;
  }

  /** 某标签下的图片张数 */
  countForTag(tagId: string): number {
    const option: LocalImageTagOption | null = findOption(this.tagOptions, tagId);
    return option === null ? 0 : option.imageCount;
  }

  /**
   * 逐张导入图片(池子,无归属)。
   * 默认名取源 URI 的文件名去扩展名;非法或重名时退化为 图片1、图片2…
   * 描述留空,导入后在图片行编辑。
   */
  async importImages(sourceUris: string[]): Promise<number> {
    if (this.disposed || this.isOperating) {
      return 0;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    let success: number = 0;
    const failures: string[] = [];
    try {
      // 池子里已占用的名字键(名字全局唯一)
      const taken: string[] = [];
      for (let i = 0; i < this.entries.length; i++) {
        taken.push(this.entries[i].image.nameKey);
      }
      for (let i = 0; i < sourceUris.length; i++) {
        const uri: string = sourceUris[i];
        const name: string = pickUniqueName(basenameWithoutExtension(uri), taken);
        try {
          await this.imageService.addImage(uri, name, '');
          taken.push(normalizeImageName(name));
          success = success + 1;
        } catch (e) {
          failures.push((e as Error).message ?? String(e));
          Logger.warn(LOG_TAG, 'addImage failed: ' + String(e));
        }
      }
      await this.refresh();
    } catch (e) {
      failures.push(String(e));
      Logger.error(LOG_TAG, 'importImages failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
    if (success > 0) {
      this.successMessage = '成功导入 ' + success.toString() + ' 张图片';
    }
    if (failures.length > 0) {
      this.errorMessage = '部分图片导入失败:' + failures.join(';');
    }
    return success;
  }

  /** 改名(全局唯一;服务会同步标签预设正文里的条目名) */
  async renameImage(id: string, name: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      await this.imageService.renameImage(id, name);
      this.successMessage = '已重命名';
      await this.refresh();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'renameImage failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 改描述(服务会同步标签预设正文里的条目描述) */
  async updateDescription(id: string, description: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      await this.imageService.updateImageDescription(id, description);
      this.successMessage = '已保存描述';
      await this.refresh();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'updateDescription failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 新建标签(= 新建一个空正文的提示词预设) */
  async createTag(name: string): Promise<boolean> {
    if (this.disposed || this.isOperating) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    let ok: boolean = false;
    try {
      await this.imageService.createTagPreset(name);
      this.successMessage = '已新建标签';
      await this.refresh();
      ok = true;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'createTag failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
    return ok;
  }

  /**
   * 设置某张图的标签(整组替换语义,内部算差集):
   * 新增的 ⇒ 把「名字(:描述)」写进那些预设正文;取消的 ⇒ 从正文删掉该条目。
   */
  async setImageTags(imageId: string, nextTagIds: string[]): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    const currentIds: string[] = this.tagIdsOf(imageId);
    const addIds: string[] = [];
    for (let i = 0; i < nextTagIds.length; i++) {
      if (currentIds.indexOf(nextTagIds[i]) < 0) {
        addIds.push(nextTagIds[i]);
      }
    }
    const removeIds: string[] = [];
    for (let i = 0; i < currentIds.length; i++) {
      if (nextTagIds.indexOf(currentIds[i]) < 0) {
        removeIds.push(currentIds[i]);
      }
    }
    if (addIds.length === 0 && removeIds.length === 0) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      await this.imageService.attachImageToPresets(imageId, addIds);
      await this.imageService.detachImageFromPresets(imageId, removeIds);
      this.successMessage = '已更新标签';
      await this.refresh();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'setImageTags failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 某张图当前的标签 id(从展示条目取) */
  tagIdsOf(imageId: string): string[] {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].image.id === imageId) {
        return this.entries[i].tagIds;
      }
    }
    return [];
  }

  requestDelete(id: string): void {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.pendingDeleteId = id;
    this.showDeleteConfirm = true;
    this.errorMessage = '';
  }

  cancelDelete(): void {
    this.pendingDeleteId = '';
    this.showDeleteConfirm = false;
  }

  async confirmDelete(id: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      await this.imageService.removeImage(id);
      this.pendingDeleteId = '';
      this.showDeleteConfirm = false;
      this.successMessage = '已删除';
      await this.refresh();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'confirmDelete failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  dispose(): void {
    this.disposed = true;
  }
}

/** 选取可用名字:合法且未占用则直接用;否则退化为 图片N(N 自增到未占用) */
function pickUniqueName(base: string, taken: string[]): string {
  if (isValidImageName(base) && taken.indexOf(normalizeImageName(base)) < 0) {
    return base.trim();
  }
  let n: number = 1;
  while (taken.indexOf(normalizeImageName('图片' + n.toString())) >= 0) {
    n = n + 1;
  }
  return '图片' + n.toString();
}

/** 从文件 URI 中提取不含扩展名的文件名(用于命名缺失时的兜底) */
function basenameWithoutExtension(uri: string): string {
  const idx: number = uri.lastIndexOf('/');
  let name: string = idx >= 0 ? uri.substring(idx + 1) : uri;
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 非合法编码则原样使用
  }
  const qIdx: number = name.indexOf('?');
  if (qIdx >= 0) {
    name = name.substring(0, qIdx);
  }
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}