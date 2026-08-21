/**
 * PersonaViewModel 用户身份页面状态管理
 *
 * 用户身份页面的 ViewModel,管理 Persona 的 CRUD 和全局默认选择。
 * 不直接操作 PersonaRepository 或 Preferences。
 */

import {
  Persona,
  PersonaUpdates
} from '../models/Persona';
import { PersonaPosition } from '../models/PersonaPosition';
import { PersonaService } from '../services/PersonaService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PersonaViewModel';

@Observed
export class PersonaViewModel {
  personas: Persona[] = [];
  defaultPersonaId: string | null = null;
  loading: boolean = false;
  errorMessage: string = '';

  /** 数据变更回调,用于页面将 @State 变量同步到 ViewModel */
  onDataUpdate: (() => void) | null = null;

  /** 删除确认 */
  deleteTarget: Persona | null = null;

  private readonly service: PersonaService;

  constructor(service: PersonaService) {
    this.service = service;
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.personas = await this.service.list();
      this.defaultPersonaId = await this.service.getDefaultPersonaId();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '加载用户身份列表失败';
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  private notifyDataUpdate(): void {
    if (this.onDataUpdate !== null) {
      this.onDataUpdate();
    }
  }

  isDefault(persona: Persona): boolean {
    return this.defaultPersonaId === persona.id;
  }

  async setDefault(persona: Persona): Promise<void> {
    this.errorMessage = '';
    try {
      if (this.defaultPersonaId === persona.id) {
        await this.service.setDefaultPersonaId(null);
        this.defaultPersonaId = null;
      } else {
        await this.service.setDefaultPersonaId(persona.id);
        this.defaultPersonaId = persona.id;
      }
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '设置默认身份失败';
      Logger.error(LOG_TAG, 'setDefault failed: ' + String(e));
    }
  }

  async deletePersona(persona: Persona): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.delete(persona.id);
      // 重新加载列表(默认引用可能已被清理)
      this.personas = await this.service.list();
      this.defaultPersonaId = await this.service.getDefaultPersonaId();
      this.deleteTarget = null;
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '删除身份失败';
      Logger.error(LOG_TAG, 'deletePersona failed: ' + String(e));
    }
  }

  // ===== 编辑页面辅助 =====

  /**
   * 创建新 Persona
   */
  async createPersona(
    name: string,
    description: string = '',
    avatarUri: string = '',
    position: PersonaPosition = PersonaPosition.BeforeCharacter,
    depth: number = 4
  ): Promise<Persona | null> {
    this.errorMessage = '';
    try {
      const persona: Persona = await this.service.create(name, description, avatarUri, position, depth);
      this.personas = await this.service.list();
      this.notifyDataUpdate();
      return persona;
    } catch (e) {
      this.errorMessage = String(e).replace('Error: ', '');
      Logger.error(LOG_TAG, 'createPersona failed: ' + String(e));
      return null;
    }
  }

  /**
   * 更新 Persona
   */
  async updatePersona(persona: Persona, updates: PersonaUpdates): Promise<Persona | null> {
    this.errorMessage = '';
    try {
      const updated: Persona = await this.service.update(persona, updates);
      this.personas = await this.service.list();
      this.notifyDataUpdate();
      return updated;
    } catch (e) {
      this.errorMessage = String(e).replace('Error: ', '');
      Logger.error(LOG_TAG, 'updatePersona failed: ' + String(e));
      return null;
    }
  }

  /** 获取 Position 的显示名称 */
  getPositionLabel(position: PersonaPosition): string {
    if (position === PersonaPosition.Disabled) {
      return '不注入';
    }
    if (position === PersonaPosition.BeforeCharacter) {
      return '角色定义之前';
    }
    if (position === PersonaPosition.AfterCharacter) {
      return '角色定义之后';
    }
    if (position === PersonaPosition.AtDepth) {
      return '聊天历史指定深度';
    }
    return '未知';
  }
}
