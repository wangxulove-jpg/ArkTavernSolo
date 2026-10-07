/**
 * LocalImageRepository
 *
 * 职责:
 * - LocalImage 的 CRUD 操作(图片池:全部图片一张表,不再按角色分层)
 * - 列表稳定排序(name_key ASC)
 * - 行映射走 LocalImageRepositoryMapper,损坏数据抛 InvalidData
 * - 不打印 name / fileUri
 *
 * 不负责:
 * - 图片文件读写(见 LocalImageAssetStore)
 * - 引用解析 / 注入(见上层服务)
 * - 标签(= 提示词预设正文,见 utils/LocalImageTagText)
 *
 * 规则:
 * - insert / updateName 时名字重复(UNIQUE 冲突)映射为 AlreadyExists(名字全局唯一)
 * - update 目标不存在返回 NotFound
 * - remove 幂等
 * - 不修改输入 LocalImage 对象
 * - ResultSet 所有路径关闭
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { LocalImage, validateLocalImage } from '../models/LocalImage';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_LOCAL_IMAGES,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_IMAGE_NAME_KEY,
  COLUMN_IMAGE_DESCRIPTION,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  localImageFromRow,
  buildLocalImageValues
} from './LocalImageRepositoryMapper';
import {
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

export class LocalImageRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(image: LocalImage): Promise<void> {
    validateLocalImage(image);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = buildLocalImageValues(image);
    try {
      await store.insert(TABLE_LOCAL_IMAGES, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('localImage.insert');
      }
      throw DatabaseError.queryFailed(
        `localImage.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  async getById(id: string): Promise<LocalImage | null> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('localImage.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return localImageFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /** 全部图片(按名字升序,稳定) */
  async listAll(): Promise<LocalImage[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.orderByAsc(COLUMN_IMAGE_NAME_KEY);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const images: LocalImage[] = [];
      while (rs.goToNextRow()) {
        images.push(localImageFromRow(rs));
      }
      return images;
    } finally {
      rs.close();
    }
  }

  async updateName(
    id: string,
    name: string,
    nameKey: string,
    updatedAt: number
  ): Promise<void> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('localImage.updateName: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_NAME] = name;
    bucket[COLUMN_IMAGE_NAME_KEY] = nameKey;
    bucket[COLUMN_UPDATED_AT] = updatedAt;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.equalTo(COLUMN_ID, id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('localImage.updateName');
      }
      throw DatabaseError.queryFailed(
        `localImage.updateName: ${extractCauseMessage(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('localImage.updateName');
    }
  }

  /** 更新图片描述(可空) */
  async updateDescription(id: string, description: string, updatedAt: number): Promise<void> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('localImage.updateDescription: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_IMAGE_DESCRIPTION] = description;
    bucket[COLUMN_UPDATED_AT] = updatedAt;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.equalTo(COLUMN_ID, id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `localImage.updateDescription: ${extractCauseMessage(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('localImage.updateDescription');
    }
  }

  async remove(id: string): Promise<void> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('localImage.remove: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `localImage.remove: ${extractCauseMessage(err)}`
      );
    }
  }

  /** 名字是否已被占用(名字全局唯一) */
  async nameTaken(nameKey: string): Promise<boolean> {
    if (nameKey.length === 0) {
      return false;
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOCAL_IMAGES);
    predicates.equalTo(COLUMN_IMAGE_NAME_KEY, nameKey);
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates);
      try {
        return rs.goToFirstRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      throw DatabaseError.queryFailed(
        `localImage.nameTaken: ${extractCauseMessage(err)}`
      );
    }
  }
}