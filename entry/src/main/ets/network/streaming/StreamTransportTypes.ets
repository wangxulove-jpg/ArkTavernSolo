/**
 * StreamTransportTypes 流式传输层类型
 *
 * 定义流式 HTTP 传输的状态机与回调类型。
 * 不依赖 @ohos.net.http,纯类型定义。
 */

import { NetworkError } from '../../models/NetworkError';

/**
 * 流式传输状态。
 * 用于实现幂等的 abort 和单次 complete/error 通知。
 */
export enum TransportState {
  /** 初始状态,尚未发起请求 */
  IDLE = 'IDLE',
  /** 请求已发起,正在接收数据 */
  RECEIVING = 'RECEIVING',
  /** 已完成(正常结束) */
  COMPLETED = 'COMPLETED',
  /** 已出错 */
  ERRORED = 'ERRORED',
  /** 已取消(主动 abort) */
  ABORTED = 'ABORTED'
}

/**
 * 流式传输回调。
 * 与 HttpClient.StreamCallbacks 类似,但增加 onDataReceive 用于字节级回调诊断。
 */
export interface TransportCallbacks {
  /**
   * 收到 HTTP 响应头时调用。
   * @param statusCode HTTP 状态码
   * @param headers 响应头(Map)
   */
  onHeaders?: (statusCode: number, headers: Map<string, string>) => void;
  /**
   * 收到数据块时调用(已解码为字符串)。
   * @param chunk 字符串数据块
   * @param byteLength 原始字节长度(用于诊断)
   */
  onData: (chunk: string, byteLength: number) => void;
  /**
   * 流式响应完成时调用。
   * @param statusCode HTTP 状态码
   */
  onComplete: (statusCode: number) => void;
  /**
   * 发生错误时调用。
   * @param error 网络错误对象
   */
  onError: (error: NetworkError) => void;
}

/**
 * 判断状态是否为终态(不可再转换)。
 * @param state 当前状态
 * @returns 终态返回 true
 */
export function isTerminalState(state: TransportState): boolean {
  return state === TransportState.COMPLETED
    || state === TransportState.ERRORED
    || state === TransportState.ABORTED;
}

/**
 * 判断是否允许从当前状态转换到目标状态。
 * 终态不允许再转换。
 *
 * @param from 当前状态
 * @param to 目标状态
 * @returns 允许转换返回 true
 */
export function canTransitionTo(from: TransportState, to: TransportState): boolean {
  if (isTerminalState(from)) {
    return false;
  }
  if (from === TransportState.IDLE && to === TransportState.RECEIVING) {
    return true;
  }
  if (from === TransportState.RECEIVING) {
    return to === TransportState.COMPLETED
      || to === TransportState.ERRORED
      || to === TransportState.ABORTED;
  }
  return false;
}
