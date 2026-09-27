/**
 * ChatGenerationContext 生成类型与活动生成上下文(自 ChatService 迁出)
 *
 * 内容:
 * - ChatGenerationKind:生成类型枚举(T-6.3 / T-6.4B-1.2)
 * - ActiveGenerationContext:一次请求生命周期内的活动生成上下文
 *
 * 迁出原因:ChatSwipeController 等拆分模块与 ChatService 均需引用;
 * 置于 models 层,避免服务间圆形依赖。
 */

/**
 * 生成类型(T-6.3 / T-6.4B-1.2):
 * - NormalResponse: 普通生成,持久化走 ChatPersistenceService.updateMessage
 * - SwipeCandidate: 候选生成,持久化走 MessageSwipePersistenceService.updateCandidate
 * - BranchRegeneration: 重新生成新分支,持久化走 ChatPersistenceService.updateMessage(新 Assistant 在新 Branch 中)
 */
export enum ChatGenerationKind {
  NormalResponse = 'NormalResponse',
  SwipeCandidate = 'SwipeCandidate',
  BranchRegeneration = 'BranchRegeneration',
  AutoContinue = 'AutoContinue',
  Narrator = 'Narrator'
}

/**
 * 活动生成上下文(T-6.3 / T-6.4B-1.2)。
 * 一次请求生命周期内不可变。所有异步回调通过 operationId + 关键字段联合判断迟到。
 * 不持久化,不记录完整 ID。
 */
export interface ActiveGenerationContext {
  readonly operationId: number;
  readonly kind: ChatGenerationKind;
  readonly chatId: string;
  readonly assistantMessageId: string;
  readonly swipeCandidateIndex?: number;
  readonly branchId?: string;
  readonly forkMessageId?: string;
  readonly autoContinueStep?: 'impersonate' | 'response'; // legacy, kept for DB compat
}
