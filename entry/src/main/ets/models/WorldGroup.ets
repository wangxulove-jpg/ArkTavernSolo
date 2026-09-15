/**
 * WorldGroup 世界分组(章节记忆共享)数据模型
 *
 * 定义世界分组的数据结构、校验规则和不可变更新。
 * 复用休眠的 worlds 表作为世界分组实体(id/name/description/status/created_at/updated_at)。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - description 最长 100000 字符
 * - status 分组状态(默认 'active')
 */

import { generateUuid } from '../utils/Uuid';

/**
 * 世界分组模型。
 */
export interface WorldGroup {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly status: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_DESCRIPTION_LENGTH: number = 100000;

/**
 * 创建世界分组。
 */
export function createWorldGroup(
  name: string,
  description: string = '',
  status: string = 'active'
): WorldGroup {
  const now: number = Date.now();
  return {
    id: 'wg-' + generateUuid(),
    name: name.trim(),
    description: description.trim(),
    status: status,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 世界分组更新字段。
 */
export interface WorldGroupUpdates {
  name?: string;
  description?: string;
  status?: string;
}

/**
 * 不可变更新世界分组。
 */
export function updateWorldGroup(
  group: WorldGroup,
  updates: WorldGroupUpdates
): WorldGroup {
  return {
    id: group.id,
    name: updates.name !== undefined ? updates.name.trim() : group.name,
    description: updates.description !== undefined ? updates.description.trim() : group.description,
    status: updates.status !== undefined ? updates.status : group.status,
    createdAt: group.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 校验世界分组。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validateWorldGroup(group: WorldGroup): string | null {
  if (group.name.trim().length === 0) {
    return '世界分组名称不能为空';
  }
  if (group.name.length > MAX_NAME_LENGTH) {
    return '世界分组名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (group.description.length > MAX_DESCRIPTION_LENGTH) {
    return '世界分组描述不能超过' + MAX_DESCRIPTION_LENGTH + '个字符';
  }
  return null;
}
