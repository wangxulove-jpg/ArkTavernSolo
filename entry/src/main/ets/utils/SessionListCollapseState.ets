/**
 * SessionListCollapseState 会话列表分组(文件夹)折叠状态
 *
 * 聊天页会话列表面板(ChatSessionListPanel)与对话记录 Tab(ChatSessionRootView)共用:
 * - Preferences 持久化 key(逗号分隔的 worldId 列表)
 * - 编码/解码与折叠判定/切换纯函数
 *
 * 纯函数模块:不依赖 AppServices / Preferences,持久化读写由调用方(页面)承担。
 */

/** 分组折叠状态持久化 key(逗号分隔的 worldId 列表) */
export const SESSION_LIST_COLLAPSED_WORLD_IDS_KEY: string = 'session_list_collapsed_world_ids';

/** 解码持久化字符串为折叠分组 id 列表(空串返回空列表;空项过滤) */
export function parseCollapsedWorldIds(raw: string): string[] {
  if (raw.length === 0) {
    return [];
  }
  return raw.split(',').filter((id: string): boolean => id.length > 0);
}

/** 编码折叠分组 id 列表为持久化字符串 */
export function serializeCollapsedWorldIds(ids: string[]): string {
  return ids.join(',');
}

/** 分组是否已折叠 */
export function isWorldCollapsed(collapsedWorldIds: string[], worldId: string): boolean {
  return collapsedWorldIds.indexOf(worldId) >= 0;
}

/** 切换分组折叠状态,返回新数组(不改原数组) */
export function toggleCollapsedWorldId(collapsedWorldIds: string[], worldId: string): string[] {
  const next: string[] = collapsedWorldIds.slice();
  const idx: number = next.indexOf(worldId);
  if (idx >= 0) {
    next.splice(idx, 1);
  } else {
    next.push(worldId);
  }
  return next;
}