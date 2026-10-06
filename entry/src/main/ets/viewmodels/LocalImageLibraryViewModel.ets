/**
 * LocalImageLibraryViewModel 本地图片库页面状态管理
 *
 * 页面与 LocalImageService / CharacterService 之间的唯一桥梁。
 * 不直接依赖 Repository / DbHelper / Preferences。
 *
 * 数据流:图片库(单一数据源)+ 角色列表 → 组装展示条目与分组(全局 / 各角色 / 孤儿)。
 */

import { LocalImage, isValidImageName, normalizeImageName } from '../models/LocalImage';
import { Character } from '../models/Character';
import { LocalImageService } from '../services/LocalImageService';
import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LocalImageLibraryViewModel';

/** 全局作用域的选择项标签 */
const GLOBAL_SCOPE_LABEL: string = '全局(所有会话)';
/** 全局分组的标题 */
const GLOBAL_GROUP_LABEL: string = '全局';
/** 角色已删除的标签(条目作用域标签与孤儿分组标题共用) */
const ORPHAN_GROUP_LABEL: string = '角色已删除';

/** 作用域选择项('' = 全局) */
export interface ScopeOption {
  readonly characterId: string;
  readonly label: string;
}

/** 展示用条目 */
export interface LocalImageEntry {
  readonly image: LocalImage;
  readonly scopeLabel: string;
  /** 角色 id 存在但角色已删除 */
  readonly orphan: boolean;
}

/** 展示用分组 */
export interface LocalImageGroup {
  readonly key: string;
  readonly label: string;
  readonly orphan: boolean;
  readonly entries: LocalImageEntry[];
}

@Observed
export class LocalImageLibraryViewModel {
  /** 展示用条目(扁平,含作用域标签) */
  entries: LocalImageEntry[] = [];
  /** 展示用分组(全局 / 各角色 / 孤儿) */
  groups: LocalImageGroup[] = [];
  /** 作用域选择项(首项固定全局) */
  scopeOptions: ScopeOption[] = [{ characterId: '', label: GLOBAL_SCOPE_LABEL }];
  /** 列表数据版本(每次刷新自增,用于 ForEach key,确保条目内容变更后重建) */
  version: number = 0;

  isLoading: boolean = false;
  isOperating: boolean = false;
  errorMessage: string = '';
  successMessage: string = '';
  showDeleteConfirm: boolean = false;
  pendingDeleteId: string = '';

  private readonly imageService: LocalImageService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor(imageService: LocalImageService, characterService: CharacterService) {
    this.imageService = imageService;
    this.characterService = characterService;
  }

  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.refresh();
  }

  /** 重新加载图片库与角色列表,重建条目与分组。 */
  async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const images: LocalImage[] = await this.imageService.listImages();
      const characters: Character[] = await this.characterService.listSummaries();

      const options: ScopeOption[] = [{ characterId: '', label: GLOBAL_SCOPE_LABEL }];
      for (let i = 0; i < characters.length; i++) {
        options.push({ characterId: characters[i].id, label: characters[i].name });
      }

      const entries: LocalImageEntry[] = [];
      for (let i = 0; i < images.length; i++) {
        const image: LocalImage = images[i];
        if (image.characterId.length === 0) {
          entries.push({ image: image, scopeLabel: GLOBAL_GROUP_LABEL, orphan: false });
        } else {
          const name: string = resolveCharacterName(characters, image.characterId);
          if (name.length > 0) {
            entries.push({ image: image, scopeLabel: name, orphan: false });
          } else {
            entries.push({ image: image, scopeLabel: ORPHAN_GROUP_LABEL, orphan: true });
          }
        }
      }

      this.scopeOptions = options;
      this.entries = entries;
      this.groups = buildGroups(entries, options);
      this.version = this.version + 1;
    } catch (e) {
      this.errorMessage = '加载本地图片库失败';
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 逐张导入图片。
   * 每张默认名取源 URI 的文件名去扩展名;非法或在该作用域已存在时退化为 图片1、图片2…
   * 失败项收集到 errorMessage,单张失败不影响其余。
   *
   * @param sourceUris 系统选择器返回的源 URI 列表
   * @param characterId '' = 全局;非空 = 该角色专属
   * @returns 成功导入的张数
   */
  async importImages(sourceUris: string[], characterId: string): Promise<number> {
    if (this.disposed || this.isOperating) {
      return 0;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    let success: number = 0;
    const failures: string[] = [];
    try {
      // 该作用域下已占用的名字键(用于避免重名)
      const taken: string[] = [];
      for (let i = 0; i < this.entries.length; i++) {
        if (this.entries[i].image.characterId === characterId) {
          taken.push(this.entries[i].image.nameKey);
        }
      }
      for (let i = 0; i < sourceUris.length; i++) {
        const uri: string = sourceUris[i];
        const name: string = pickUniqueName(basenameWithoutExtension(uri), taken);
        try {
          await this.imageService.addImage(uri, name, characterId);
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

  /** 改名(同一作用域内不可重名) */
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

  /** 改作用域('' = 全局) */
  async changeScope(id: string, characterId: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      await this.imageService.changeScope(id, characterId);
      this.successMessage = '已切换作用域';
      await this.refresh();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? String(e);
      Logger.error(LOG_TAG, 'changeScope failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
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

/** 按 id 解析角色名(角色已删除时返回空串) */
function resolveCharacterName(characters: Character[], characterId: string): string {
  for (let i = 0; i < characters.length; i++) {
    if (characters[i].id === characterId) {
      return characters[i].name;
    }
  }
  return '';
}

/** 组装分组:全局 → 各角色(按传入顺序)→ 孤儿;空分组不输出 */
function buildGroups(entries: LocalImageEntry[], options: ScopeOption[]): LocalImageGroup[] {
  const groups: LocalImageGroup[] = [];

  const globalEntries: LocalImageEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    if (!entries[i].orphan && entries[i].image.characterId.length === 0) {
      globalEntries.push(entries[i]);
    }
  }
  if (globalEntries.length > 0) {
    groups.push({
      key: 'global',
      label: GLOBAL_GROUP_LABEL,
      orphan: false,
      entries: globalEntries
    });
  }

  for (let i = 0; i < options.length; i++) {
    const option: ScopeOption = options[i];
    if (option.characterId.length === 0) {
      continue;
    }
    const own: LocalImageEntry[] = [];
    for (let j = 0; j < entries.length; j++) {
      if (!entries[j].orphan && entries[j].image.characterId === option.characterId) {
        own.push(entries[j]);
      }
    }
    if (own.length > 0) {
      groups.push({
        key: option.characterId,
        label: option.label,
        orphan: false,
        entries: own
      });
    }
  }

  const orphans: LocalImageEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].orphan) {
      orphans.push(entries[i]);
    }
  }
  if (orphans.length > 0) {
    groups.push({
      key: '__orphan__',
      label: ORPHAN_GROUP_LABEL,
      orphan: true,
      entries: orphans
    });
  }

  return groups;
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

/** 从文件 URI 中提取不含扩展名的文件名(用于命名缺失时的兜底)。 */
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