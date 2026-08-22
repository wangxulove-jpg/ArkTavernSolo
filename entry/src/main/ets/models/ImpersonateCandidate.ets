/**
 * ImpersonateCandidate 代写候选模型
 *
 * AI 代写生成的待选用户消息,仅用于 UI 展示和选择,不持久化。
 * 选择后通过正常 sendMessage 流程发送,因此最终消息的 senderType='user'。
 */

export interface ImpersonateCandidate {
  readonly index: number;
  readonly content: string;
}
