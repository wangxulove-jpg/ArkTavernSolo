/**
 * ChatStatusState 角色状态模型
 *
 * 描述聊天页顶部「角色状态卡片」中的一组键值状态(如 服装 / 地点 / 金币)。
 * - 用户可手动添加/修改/删除/锁定字段
 * - AI 每轮回复末尾输出隐藏 JSON 状态块,解析后合并更新
 * - 被锁定的字段在 AI 未输出时也保留
 *
 * 约束:
 * - 不依赖 ArkUI / ViewModel / 网络层
 * - 不使用 any
 * - JSON.parse 结果必须经安全提取,不直接断言为接口
 */

/**
 * 单个状态字段。
 */
export interface ChatStatusEntry {
  /** 字段名(如 "服装") */
  name: string;
  /** 当前值(数字也统一转为字符串,如 "120") */
  value: string;
  /** true=用户手动添加,false=AI 补充 */
  fromUser: boolean;
  /** true=锁定,AI 未输出该字段时也保留 */
  locked: boolean;
}

/**
 * 一组角色状态。
 */
export interface ChatStatusState {
  /** 有序列表:用户字段在前,AI 补充字段在后 */
  entries: ChatStatusEntry[];
}

/**
 * 创建单个状态字段。
 */
export function createChatStatusEntry(
  name: string,
  value: string,
  fromUser: boolean,
  locked: boolean
): ChatStatusEntry {
  return {
    name: name,
    value: value,
    fromUser: fromUser,
    locked: locked
  };
}

/**
 * 创建空状态。
 */
export function createEmptyChatStatusState(): ChatStatusState {
  return {
    entries: []
  };
}

/**
 * 序列化为 JSON 字符串(用于持久化到 chats.status_config_json)。
 */
export function serializeChatStatusState(state: ChatStatusState): string {
  const entries: ChatStatusEntryJson[] = [];
  for (let i = 0; i < state.entries.length; i++) {
    const e: ChatStatusEntry = state.entries[i];
    entries.push({
      name: e.name,
      value: e.value,
      fromUser: e.fromUser,
      locked: e.locked
    });
  }
  return JSON.stringify({ entries: entries });
}

/**
 * 从 JSON 字符串反序列化。空/非法 JSON 返回空态(不抛错)。
 */
export function parseChatStatusState(json: string): ChatStatusState {
  if (json.length === 0) {
    return createEmptyChatStatusState();
  }
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    const rawEntries: Object | undefined = obj['entries'];
    if (!(rawEntries instanceof Array)) {
      return createEmptyChatStatusState();
    }
    const entries: ChatStatusEntry[] = [];
    const arr: Object[] = rawEntries as Object[];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      const io: Record<string, Object> = item as Record<string, Object>;
      const name: string = typeof io['name'] === 'string' ? (io['name'] as string) : '';
      if (name.length === 0) {
        continue;
      }
      const value: string = typeof io['value'] === 'string' ? (io['value'] as string) : '';
      const fromUser: boolean = typeof io['fromUser'] === 'boolean' ? (io['fromUser'] as boolean) : false;
      const locked: boolean = typeof io['locked'] === 'boolean' ? (io['locked'] as boolean) : false;
      entries.push(createChatStatusEntry(name, value, fromUser, locked));
    }
    return { entries: entries };
  } catch (e) {
    return createEmptyChatStatusState();
  }
}

/**
 * JSON 序列化辅助接口(内部使用)。
 */
interface ChatStatusEntryJson {
  name: string;
  value: string;
  fromUser: boolean;
  locked: boolean;
}
