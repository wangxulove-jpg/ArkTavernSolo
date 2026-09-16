/**
 * ChatLorebookPin Repository(按需锁定世界书会话钉选)
 *
 * 职责:
 * - chat_lorebook_pins 表的读写(每个 chat 一行,chat_id 主键)
 * - 记录 OnDemandPinned 模式世界书在当前会话固定注入的条目 ID 列表
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
  TABLE_CHAT_LOREBOOK_PINS,
  COLUMN_PIN_CHAT_ID,
  COLUMN_PIN_LOREBOOK_ID,
  COLUMN_PIN_ENTRY_IDS_JSON,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';

/** 会话钉选记录(不可变模型) */
export interface ChatLorebookPin {
  readonly chatId: string;
  readonly lorebookId: string;
  readonly entryIds: string[];
  readonly createdAt: number;
  readonly updatedAt: number;
}

export class ChatLorebookPinRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  /**
   * 查询会话钉选记录,无记录返回 null。
   */
  async getByChatId(chatId: string): Promise<ChatLorebookPin | null> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookPin getByChatId: chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_LOREBOOK_PINS);
    predicates.equalTo(COLUMN_PIN_CHAT_ID, chatId);
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
   * 插入或替换会话钉选记录(按 chat_id 主键)。
   */
  async upsert(pin: ChatLorebookPin): Promise<void> {
    if (pin.chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookPin upsert: chatId empty');
    }
    if (pin.lorebookId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookPin upsert: lorebookId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_PIN_CHAT_ID] = pin.chatId;
    bucket[COLUMN_PIN_LOREBOOK_ID] = pin.lorebookId;
    bucket[COLUMN_PIN_ENTRY_IDS_JSON] = JSON.stringify(pin.entryIds);
    bucket[COLUMN_CREATED_AT] = pin.createdAt;
    bucket[COLUMN_UPDATED_AT] = pin.updatedAt;
    await store.insert(
      TABLE_CHAT_LOREBOOK_PINS,
      bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE
    );
  }

  /**
   * 删除会话钉选记录(会话删除级联清理时使用)。
   */
  async removeByChatId(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ChatLorebookPin removeByChatId: chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_LOREBOOK_PINS);
    predicates.equalTo(COLUMN_PIN_CHAT_ID, chatId);
    await store.delete(predicates);
  }

  private fromRow(rs: relationalStore.ResultSet): ChatLorebookPin {
    const chatIdIndex: number = rs.getColumnIndex(COLUMN_PIN_CHAT_ID);
    const lorebookIdIndex: number = rs.getColumnIndex(COLUMN_PIN_LOREBOOK_ID);
    const entryIdsIndex: number = rs.getColumnIndex(COLUMN_PIN_ENTRY_IDS_JSON);
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
