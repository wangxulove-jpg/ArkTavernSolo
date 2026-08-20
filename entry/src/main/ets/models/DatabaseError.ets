/**
 * 数据库错误模型
 *
 * 公开错误不包含:
 * - SQL 全文
 * - 聊天正文
 * - 数据库文件绝对路径
 * - 原始 BusinessError 对象
 *
 * 仅暴露:
 * - 错误类型枚举
 * - 脱敏后的 causeMessage(用于日志/调试)
 */

export enum DatabaseErrorType {
  NotInitialized,
  OpenFailed,
  SchemaFailed,
  MigrationFailed,
  TransactionFailed,
  UnsupportedVersion,
  QueryFailed,
  Closed,
  NotFound,
  AlreadyExists,
  InvalidData,
  ConstraintFailed
}

export class DatabaseError extends Error {
  readonly type: DatabaseErrorType;
  readonly causeMessage: string;

  constructor(type: DatabaseErrorType, message: string, causeMessage: string = '') {
    super(message);
    this.name = 'DatabaseError';
    this.type = type;
    this.causeMessage = causeMessage;
  }

  static notInitialized(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.NotInitialized,
      'database not initialized',
      cause
    );
  }

  static closed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.Closed,
      'database closed',
      cause
    );
  }

  static openFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.OpenFailed,
      'failed to open database',
      cause
    );
  }

  static schemaFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.SchemaFailed,
      'failed to create schema',
      cause
    );
  }

  static migrationFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.MigrationFailed,
      'failed to execute migration',
      cause
    );
  }

  static transactionFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.TransactionFailed,
      'transaction failed',
      cause
    );
  }

  static unsupportedVersion(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.UnsupportedVersion,
      'database version not supported',
      cause
    );
  }

  static queryFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.QueryFailed,
      'query failed',
      cause
    );
  }

  static notFound(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.NotFound,
      'record not found',
      cause
    );
  }

  static alreadyExists(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.AlreadyExists,
      'record already exists',
      cause
    );
  }

  static invalidData(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.InvalidData,
      'invalid data',
      cause
    );
  }

  static constraintFailed(cause: string = ''): DatabaseError {
    return new DatabaseError(
      DatabaseErrorType.ConstraintFailed,
      'constraint failed',
      cause
    );
  }
}

export function isDatabaseError(e: Error | Object): boolean {
  return e instanceof DatabaseError;
}
