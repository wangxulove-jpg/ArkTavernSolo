/**
 * CharacterEditViewModel 角色编辑页面状态管理
 *
 * 全屏角色编辑页(UI-3B-2)与 CharacterService 之间的唯一桥梁。
 * 表单状态通过 getFormState() 返回快照给页面,由页面 @State formState 持有。
 *
 * 设计:
 * - 与 CharacterListViewModel 解耦:本 ViewModel 只负责单角色的加载/保存/新建
 * - 不持有角色列表状态
 * - 不直接依赖 Repository / 数据库
 * - 路由参数解析放在 parseCharacterEditRouteParam,页面 onReady 调用
 *
 * 复用:
 * - CharacterService.list/getById/create/update
 * - 不修改 Character 数据模型
 * - 不修改数据库 Schema
 * - 不修改导入/导出逻辑
 *
 * 字段策略:
 * - tags / creator / character_version / creator_notes 只作元数据,不进入 PromptBuilder
 * - alternate_greetings 作为开场白的额外 Swipe 候选
 * - mes_example 作为对话示例进入 PromptBuilder
 * - system_prompt / post_history_instructions 按 PromptBuilder 配置启用
 * - extensions 原样保存,不暴露到 UI
 * - character_book 复用 Lorebook 编辑能力(只展示关联 ID)
 */

import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterEditViewModel';

// ===== 表单状态快照 =====

/**
 * 角色编辑表单状态快照。
 * 页面通过 @State formState 持有,ViewModel 不持有 ArkUI 状态。
 */
export interface CharacterEditFormState {
  /** 角色名称(必填) */
  nameInput: string;
  /** 角色对你的称呼(留空时使用全局用户称呼) */
  userNameInput: string;
  /** 角色描述 */
  descriptionInput: string;
  /** 角色性格 */
  personalityInput: string;
  /** 场景 */
  scenarioInput: string;
  /** 开场白(作为 Candidate 0) */
  firstMessageInput: string;
  /** System Prompt(角色专属,空时使用默认组合) */
  systemPromptInput: string;
  /** 头像 URI(即时落库,仅展示) */
  avatarUriInput: string;
  /** 对话示例(进入 PromptBuilder 作为示例消息) */
  mesExampleInput: string;
  /** 创作者备注(元数据,不进入 Prompt) */
  creatorNotesInput: string;
  /** Post-History Instructions(放在聊天历史之后,生成请求之前) */
  postHistoryInstructionsInput: string;
  /** 备用开场白列表(作为 Swipe 候选 1..N) */
  alternateGreetingsInput: string[];
  /** 标签列表(元数据,不进入 Prompt) */
  tagsInput: string[];
  /** 创作者名(元数据,不进入 Prompt) */
  creatorInput: string;
  /** 角色卡版本(元数据,不进入 Prompt) */
  characterVersionInput: string;
  /** 角色专属世界书 ID(只读展示,关联 lorebooks.id) */
  characterBookIdInput: string;
}

/** 空表单(新建模式) */
export function emptyFormState(): CharacterEditFormState {
  return {
    nameInput: '',
    userNameInput: '',
    descriptionInput: '',
    personalityInput: '',
    scenarioInput: '',
    firstMessageInput: '',
    systemPromptInput: '',
    avatarUriInput: '',
    mesExampleInput: '',
    creatorNotesInput: '',
    postHistoryInstructionsInput: '',
    alternateGreetingsInput: [],
    tagsInput: [],
    creatorInput: '',
    characterVersionInput: '',
    characterBookIdInput: ''
  };
}

/** 复制表单快照(深拷贝数组,用于不可变更新) */
export function copyFormState(state: CharacterEditFormState): CharacterEditFormState {
  return {
    nameInput: state.nameInput,
    userNameInput: state.userNameInput,
    descriptionInput: state.descriptionInput,
    personalityInput: state.personalityInput,
    scenarioInput: state.scenarioInput,
    firstMessageInput: state.firstMessageInput,
    systemPromptInput: state.systemPromptInput,
    avatarUriInput: state.avatarUriInput,
    mesExampleInput: state.mesExampleInput,
    creatorNotesInput: state.creatorNotesInput,
    postHistoryInstructionsInput: state.postHistoryInstructionsInput,
    alternateGreetingsInput: state.alternateGreetingsInput.slice(),
    tagsInput: state.tagsInput.slice(),
    creatorInput: state.creatorInput,
    characterVersionInput: state.characterVersionInput,
    characterBookIdInput: state.characterBookIdInput
  };
}

/** 从 Character 实例构建表单快照(编辑模式回填) */
function formStateFromCharacter(character: Character): CharacterEditFormState {
  return {
    nameInput: character.name,
    userNameInput: character.userName,
    descriptionInput: character.description,
    personalityInput: character.personality,
    scenarioInput: character.scenario,
    firstMessageInput: character.firstMessage,
    systemPromptInput: character.systemPrompt,
    avatarUriInput: character.avatarUri,
    mesExampleInput: character.mesExample,
    creatorNotesInput: character.creatorNotes,
    postHistoryInstructionsInput: character.postHistoryInstructions,
    alternateGreetingsInput: character.alternateGreetings.slice(),
    tagsInput: character.tags.slice(),
    creatorInput: character.creator,
    characterVersionInput: character.characterVersion,
    characterBookIdInput: character.characterBookId
  };
}

// ===== 路由参数解析 =====

/**
 * 路由参数结构:
 * - characterId 为空字符串或 undefined -> 新建模式
 * - characterId 非空 -> 编辑模式
 */
export interface ParsedCharacterEditRoute {
  readonly characterId: string | undefined;
  readonly error: string | undefined;
}

/**
 * 解析路由参数。
 * 兼容 NavPathStack.pushPath({ name, param }) 传入的对象。
 */
export function parseCharacterEditRouteParam(param: Object | undefined): ParsedCharacterEditRoute {
  if (param === undefined) {
    return { characterId: undefined, error: undefined };
  }
  const record = param as Record<string, Object | undefined>;
  const idVal = record['characterId'];
  if (idVal === undefined) {
    // 没有 characterId 字段视为新建
    return { characterId: undefined, error: undefined };
  }
  if (typeof idVal !== 'string') {
    return { characterId: undefined, error: '页面参数错误:characterId 类型无效' };
  }
  return { characterId: idVal, error: undefined };
}

// ===== ViewModel =====

export class CharacterEditViewModel {
  /** 是否为编辑模式(否则为新建模式) */
  isEditing: boolean = false;
  /** 当前编辑的角色 ID(新建模式为空) */
  editingCharacterId: string = '';

  private readonly characterService: CharacterService;
  private disposed: boolean = false;
  /** 加载到的原始角色(用于脏检测;新建模式为 null) */
  private originalCharacter: Character | null = null;

  constructor(characterService: CharacterService) {
    this.characterService = characterService;
  }

  /**
   * 初始化:根据 characterId 加载角色。
   * - characterId 为空或 undefined:新建模式,返回空表单
   * - characterId 非空:编辑模式,加载角色
   * - 角色不存在:抛出错误
   */
  async initialize(characterId: string | undefined): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (characterId === undefined || characterId.length === 0) {
      // 新建模式
      this.isEditing = false;
      this.editingCharacterId = '';
      this.originalCharacter = null;
      return;
    }
    // 编辑模式
    const character: Character | null = await this.characterService.getById(characterId);
    if (character === null) {
      this.isEditing = false;
      this.editingCharacterId = '';
      this.originalCharacter = null;
      throw new Error('角色不存在或已被删除');
    }
    this.isEditing = true;
    this.editingCharacterId = character.id;
    this.originalCharacter = character;
  }

  /**
   * 获取当前表单快照。
   * 编辑模式:从原始角色回填
   * 新建模式:返回空表单
   */
  getFormState(): CharacterEditFormState {
    if (this.originalCharacter !== null) {
      return formStateFromCharacter(this.originalCharacter);
    }
    return emptyFormState();
  }

  /**
   * 检测表单是否有未保存修改。
   * 用于返回前提示。
   *
   * 注意:avatarUriInput 在 changeAvatar 时已即时落库,
   * originalCharacter.avatarUri 也同步刷新,因此 isDirty 不比较头像字段是正确的。
   * characterBookIdInput 由独立的关联/解除关联流程处理,也不参与脏检测。
   */
  isDirty(current: CharacterEditFormState): boolean {
    if (this.originalCharacter === null) {
      // 新建模式:任意字段非空即为脏
      return current.nameInput.trim().length > 0
        || current.userNameInput.trim().length > 0
        || current.descriptionInput.length > 0
        || current.personalityInput.length > 0
        || current.scenarioInput.length > 0
        || current.firstMessageInput.length > 0
        || current.systemPromptInput.length > 0
        || current.mesExampleInput.length > 0
        || current.creatorNotesInput.length > 0
        || current.postHistoryInstructionsInput.length > 0
        || current.alternateGreetingsInput.length > 0
        || current.tagsInput.length > 0
        || current.creatorInput.length > 0
        || current.characterVersionInput.length > 0;
    }
    // 编辑模式:与原始角色比较(不比较 avatarUriInput / characterBookIdInput)
    const orig: Character = this.originalCharacter;
    return current.nameInput !== orig.name
      || current.userNameInput !== orig.userName
      || current.descriptionInput !== orig.description
      || current.personalityInput !== orig.personality
      || current.scenarioInput !== orig.scenario
      || current.firstMessageInput !== orig.firstMessage
      || current.systemPromptInput !== orig.systemPrompt
      || current.mesExampleInput !== orig.mesExample
      || current.creatorNotesInput !== orig.creatorNotes
      || current.postHistoryInstructionsInput !== orig.postHistoryInstructions
      || !arraysEqual(current.alternateGreetingsInput, orig.alternateGreetings)
      || !arraysEqual(current.tagsInput, orig.tags)
      || current.creatorInput !== orig.creator
      || current.characterVersionInput !== orig.characterVersion;
  }

  /**
   * 修改当前角色头像。
   * 仅在编辑模式下可用,新建模式下调用会抛错。
   *
   * 流程:
   * - characterService.updateAvatar(id, sourceUri):
   *   1. 保存新头像到私有目录(文件名带时间戳)
   *   2. 更新数据库 avatarUri 字段
   *   3. 清理被替换的旧头像文件
   * - 失败时旧头像保留,不修改任何内容
   * - 成功后刷新 originalCharacter,供 getFormState() 返回新 avatarUri
   *
   * @param sourceUri 源 PNG 文件 URI(由 picker 返回)
   * @returns 新的头像 URI(已写入 Character.avatarUri)
   * @throws 新建模式 / 角色不存在 / 保存失败 / 数据库更新失败时抛出
   */
  async changeAvatar(sourceUri: string): Promise<string> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    if (!this.isEditing || this.editingCharacterId.length === 0) {
      throw new Error('新建模式下不能修改头像,请先保存角色');
    }
    const updated: Character = await this.characterService.updateAvatar(
      this.editingCharacterId, sourceUri
    );
    this.originalCharacter = updated;
    return updated.avatarUri;
  }

  /**
   * 保存表单。
   * - 新建模式:调用 characterService.create
   * - 编辑模式:调用 characterService.update
   * - 名称校验:trim 后非空
   *
   * @returns 保存成功后返回新的 Character
   * @throws 校验失败或保存失败时抛出 Error
   */
  async save(current: CharacterEditFormState): Promise<Character> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    const trimmedName: string = current.nameInput.trim();
    if (trimmedName.length === 0) {
      throw new Error('角色名称不能为空');
    }

    if (this.isEditing) {
      // 编辑模式:保留 extensions / characterBookId 不变
      const updated: Character = await this.characterService.update(this.editingCharacterId, {
        name: current.nameInput,
        userName: current.userNameInput,
        description: current.descriptionInput,
        personality: current.personalityInput,
        scenario: current.scenarioInput,
        firstMessage: current.firstMessageInput,
        systemPrompt: current.systemPromptInput,
        mesExample: current.mesExampleInput,
        creatorNotes: current.creatorNotesInput,
        postHistoryInstructions: current.postHistoryInstructionsInput,
        alternateGreetings: current.alternateGreetingsInput.slice(),
        tags: current.tagsInput.slice(),
        creator: current.creatorInput,
        characterVersion: current.characterVersionInput
      });
      this.originalCharacter = updated;
      return updated;
    }

    // 新建模式:create 默认不接收新字段,使用 create + update 组合
    // 第一步:用基础字段创建(获得 ID)
    const created: Character = await this.characterService.create(
      current.nameInput,
      current.descriptionInput,
      current.personalityInput,
      current.scenarioInput,
      current.firstMessageInput,
      current.systemPromptInput
    );
    // 第二步:用 update 写入 V2 字段(单事务,失败回滚由调用方处理)
    try {
      const finalChar: Character = await this.characterService.update(created.id, {
        userName: current.userNameInput,
        mesExample: current.mesExampleInput,
        creatorNotes: current.creatorNotesInput,
        postHistoryInstructions: current.postHistoryInstructionsInput,
        alternateGreetings: current.alternateGreetingsInput.slice(),
        tags: current.tagsInput.slice(),
        creator: current.creatorInput,
        characterVersion: current.characterVersionInput
      });
      this.isEditing = true;
      this.editingCharacterId = finalChar.id;
      this.originalCharacter = finalChar;
      return finalChar;
    } catch (e) {
      // V2 字段更新失败,基础角色已创建,仍返回已创建的角色
      Logger.warn(LOG_TAG, 'save: V2 fields update failed: ' + String(e));
      this.isEditing = true;
      this.editingCharacterId = created.id;
      this.originalCharacter = created;
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('save: V2 fields update failed: ' + String(e));
    }
  }

  dispose(): void {
    this.disposed = true;
    this.originalCharacter = null;
  }
}

/** 比较两个字符串数组内容是否相等(顺序敏感) */
function arraysEqual(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
