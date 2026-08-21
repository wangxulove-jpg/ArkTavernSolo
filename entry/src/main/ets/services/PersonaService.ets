/**
 * PersonaService 用户身份业务服务
 *
 * 封装 PersonaRepository + PersonaSelectionStore,提供 Persona CRUD、
 * 全局默认管理和优先级查找。
 * 页面只通过 ViewModel 访问,不直接操作 Repository。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 不存储聊天记录
 * - 不直接操作 SQL
 */

import {
  Persona,
  PersonaUpdates,
  createPersona,
  validatePersona,
  updatePersona
} from '../models/Persona';
import { PersonaPosition } from '../models/PersonaPosition';
import { PersonaRepository } from '../repositories/PersonaRepository';
import { PersonaSelectionStore } from '../storage/PersonaSelectionStore';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PersonaService';

export class PersonaService {
  private readonly repository: PersonaRepository;
  private readonly selectionStore: PersonaSelectionStore;
  private initialized: boolean = false;

  constructor(
    repository: PersonaRepository,
    selectionStore: PersonaSelectionStore
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.selectionStore.initialize();
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('PersonaService not initialized');
    }
  }

  // ===== Persona CRUD =====

  async list(): Promise<Persona[]> {
    this.requireInit();
    return await this.repository.getAll();
  }

  async getById(id: string): Promise<Persona | null> {
    this.requireInit();
    return await this.repository.getById(id);
  }

  async create(
    name: string,
    description: string = '',
    avatarUri: string = '',
    position: PersonaPosition = PersonaPosition.BeforeCharacter,
    depth: number = 4
  ): Promise<Persona> {
    this.requireInit();
    const persona: Persona = createPersona(name, description, avatarUri, position, depth);
    const error: string | null = validatePersona(persona);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.insert(persona);
    return persona;
  }

  async update(persona: Persona, updates: PersonaUpdates): Promise<Persona> {
    this.requireInit();
    const updated: Persona = updatePersona(persona, updates);
    const error: string | null = validatePersona(updated);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.update(updated);
    return updated;
  }

  async delete(id: string): Promise<void> {
    this.requireInit();
    // 删除时清理全局默认引用
    const defaultId: string | null = await this.selectionStore.getDefaultPersonaId();
    if (defaultId !== null && defaultId === id) {
      await this.selectionStore.clear();
    }
    await this.repository.deleteById(id);
  }

  // ===== 全局默认管理 =====

  async getDefaultPersonaId(): Promise<string | null> {
    this.requireInit();
    return await this.selectionStore.getDefaultPersonaId();
  }

  async setDefaultPersonaId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null) {
      // 验证 ID 存在
      const persona: Persona | null = await this.repository.getById(id);
      if (persona === null) {
        throw new Error('Persona not found: ' + id);
      }
    }
    await this.selectionStore.setDefaultPersonaId(id);
  }

  // ===== 优先级查找 =====

  /**
   * 按优先级查找有效 Persona:
   * 1. chatPersonaId 非空 → 查找该 Persona(不存在则视为空)
   * 2. characterDefaultPersonaId 非空 → 查找该 Persona
   * 3. 全局 default_persona_id 非空 → 查找该 Persona
   * 4. 以上均无 → 返回 null
   */
  async resolveEffectivePersona(
    chatPersonaId: string,
    characterDefaultPersonaId: string
  ): Promise<Persona | null> {
    this.requireInit();

    // 1. 聊天锁定
    if (chatPersonaId.length > 0) {
      const chatPersona: Persona | null = await this.repository.getById(chatPersonaId);
      if (chatPersona !== null) {
        return chatPersona;
      }
      Logger.warn(LOG_TAG, 'Chat persona not found, falling back: ' + chatPersonaId);
    }

    // 2. 角色锁定
    if (characterDefaultPersonaId.length > 0) {
      const charPersona: Persona | null = await this.repository.getById(characterDefaultPersonaId);
      if (charPersona !== null) {
        return charPersona;
      }
      Logger.warn(LOG_TAG, 'Character default persona not found, falling back: ' + characterDefaultPersonaId);
    }

    // 3. 全局默认
    const defaultId: string | null = await this.selectionStore.getDefaultPersonaId();
    if (defaultId !== null && defaultId.length > 0) {
      const defaultPersona: Persona | null = await this.repository.getById(defaultId);
      if (defaultPersona !== null) {
        return defaultPersona;
      }
      Logger.warn(LOG_TAG, 'Default persona not found, falling back: ' + defaultId);
    }

    // 4. 无匹配
    return null;
  }
}
