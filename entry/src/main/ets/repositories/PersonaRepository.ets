/**
 * PersonaRepository
 *
 * 职责:
 * - Persona CRUD(主记录)
 * - 事务管理
 *
 * 不负责:
 * - 业务逻辑
 * - Persona 优先级查找
 * - Prompt 注入
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Persona } from '../models/Persona';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_PERSONAS,
  COLUMN_PERSONA_ID,
  COLUMN_PERSONA_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  personaFromRow,
  personaToBucket,
  validatePersona
} from './PersonaRepositoryMapper';
import {
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'PersonaRepository';

export class PersonaRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getAll(): Promise<Persona[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PERSONAS);
    predicates.orderByDesc(COLUMN_PERSONA_UPDATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const personas: Persona[] = [];
    try {
      while (rs.goToNextRow()) {
        personas.push(personaFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return personas;
  }

  async getById(id: string): Promise<Persona | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PERSONAS);
    predicates.equalTo(COLUMN_PERSONA_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return personaFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(persona: Persona): Promise<void> {
    validatePersona(persona);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_PERSONAS, personaToBucket(persona));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('persona.insert');
      }
      throw DatabaseError.queryFailed(
        `persona.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  async update(persona: Persona): Promise<void> {
    validatePersona(persona);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = personaToBucket(persona);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PERSONAS);
    predicates.equalTo(COLUMN_PERSONA_ID, persona.id);
    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `persona.update: ${extractCauseMessage(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('persona.update');
    }
  }

  async deleteById(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PERSONAS);
    predicates.equalTo(COLUMN_PERSONA_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `persona.deleteById: ${extractCauseMessage(err)}`
      );
    }
  }

  async count(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM ${TABLE_PERSONAS}`
    );
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('cnt');
        if (ci >= 0) {
          return rs.getLong(ci);
        }
      }
      return 0;
    } finally {
      rs.close();
    }
  }
}
