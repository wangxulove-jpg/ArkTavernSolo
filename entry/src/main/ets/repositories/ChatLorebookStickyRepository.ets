/**
 * ChatLorebookSticky Repository(粘滞按需世界书会话命中)
 *
 * 职责:
 * - chat_lorebook_sticky 表的读写(每个 chat 一行,chat_id 主键)
 * - 记录 StickyOnDemand 模式世界书在当前会话累计命中的条目 ID 列表
 *   (按首次命中顺序,append-only,保证注入块前缀缓存命中)
 *
 * 约定:
 * - 公开方法自行 getStore
 * - ResultSet 所有路径 finally close
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_CHAT_LOREBOOK_STICKY,
  COLUMN_STICKY_CHAT_ID,
  COLUMN_STICKY_LOREBOOK_ID,
  COLUMN_STICKY_ENTRY_IDS_JSON,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';

/** 会话粘滞命中记录(不可变模型) */
export interface ChatLorebookSticky {
  readonly chatId: string;
  readonly lorebookId: string;
  readonly entryIds: string[];
  readonly createdAt: number;
  readonly updatedAt: number;
}

export class ChatLorebookStickyRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  /**
   * 查询会话粘滞命中记录,无记录返回 null。
   */
  async getByChatId(chatId: string): Promise<ChatLorebookSticky | null> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookSticky getByChatId: chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_LOREBOOK_STICKY);
    predicates.equalTo(COLUMN_STICKY_CHAT_ID, chatId);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return this.fromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 插入或替换会话粘滞命中记录(按 chat_id 主键)。
   */
  async upsert(sticky: ChatLorebookSticky): Promise<void> {
    if (sticky.chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookSticky upsert: chatId empty');
    }
    if (sticky.lorebookId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookSticky upsert: lorebookId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STICKY_CHAT_ID] = sticky.chatId;
    bucket[COLUMN_STICKY_LOREBOOK_ID] = sticky.lorebookId;
    bucket[COLUMN_STICKY_ENTRY_IDS_JSON] = JSON.stringify(sticky.entryIds);
    bucket[COLUMN_CREATED_AT] = sticky.createdAt;
    bucket[COLUMN_UPDATED_AT] = sticky.updatedAt;
    await store.insert(
      TABLE_CHAT_LOREBOOK_STICKY,
      bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE
    );
  }

  /**
   * 删除会话粘滞命中记录(会话删除级联清理时使用)。
   */
  async removeByChatId(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookSticky removeByChatId: chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_LOREBOOK_STICKY);
    predicates.equalTo(COLUMN_STICKY_CHAT_ID, chatId);
    await store.delete(predicates);
  }

  private fromRow(rs: relationalStore.ResultSet): ChatLorebookSticky {
    const chatIdIndex: number = rs.getColumnIndex(COLUMN_STICKY_CHAT_ID);
    const lorebookIdIndex: number = rs.getColumnIndex(COLUMN_STICKY_LOREBOOK_ID);
    const entryIdsIndex: number = rs.getColumnIndex(COLUMN_STICKY_ENTRY_IDS_JSON);
    const createdIndex: number = rs.getColumnIndex(COLUMN_CREATED_AT);
    const updatedIndex: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
    return {
      chatId: rs.getString(chatIdIndex),
      lorebookId: rs.getString(lorebookIdIndex),
      entryIds: parseEntryIdsJson(rs.getString(entryIdsIndex)),
      createdAt: rs.getLong(createdIndex),
      updatedAt: rs.getLong(updatedIndex)
    };
  }
}

/** entry_ids_json 安全解析(损坏返回空数组)。 */
function parseEntryIdsJson(json: string): string[] {
  if (json.length === 0) {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    if (!Array.isArray(parsed)) {
      return [];
    }
    const result: string[] = [];
    const arr: Object[] = parsed as Object[];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string' && (arr[i] as string).length > 0) {
        result.push((arr[i] as string).trim());
      }
    }
    return result;
  } catch (_e) {
    return [];
  }
}
