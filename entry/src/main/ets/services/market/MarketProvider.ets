/**
 * MarketProvider 市场角色卡 Provider 抽象接口
 *
 * 定义统一的在线角色卡浏览/搜索/下载能力。
 * 具体 Provider(如 ChubProvider)实现此接口,将远程数据转换为 MarketCharacter 等统一模型。
 * 市场 UI 不直接依赖 Provider 原始响应结构。
 *
 * 安全约束:
 * - 所有请求必须使用 HTTPS
 * - 不记录 API Key、Authorization Header
 * - 公共浏览接口不要求用户 API Key
 * - 若 Provider 需要认证,凭证必须使用安全存储
 */

import { MarketCharacterDetail } from '../../models/MarketCharacterDetail';
import { MarketQuery, MarketPageResult } from '../../models/MarketQuery';

/**
 * 市场角色卡 Provider 抽象接口。
 */
export interface MarketProvider {
  /**
   * Provider 唯一标识(如 'chub')。
   */
  readonly providerId: string;

  /**
   * Provider 显示名称(如 'Chub')。
   */
  readonly displayName: string;

  /**
   * Provider 是否需要认证才能浏览。
   * 第一版 Chub 公共浏览接口不需要认证,返回 false。
   */
  requiresAuth(): boolean;

  /**
   * 获取角色卡列表(支持搜索/排序/分页/标签/创作者过滤)。
   *
   * @param query 查询参数
   * @returns 分页结果
   */
  searchCharacters(query: MarketQuery): Promise<MarketPageResult>;

  /**
   * 获取角色卡详情(完整字段,用于详情页)。
   *
   * @param remoteId Provider 内部角色 ID
   * @returns 角色卡详情(包含完整字段与下载 URL)
   */
  getCharacterDetail(remoteId: string): Promise<MarketCharacterDetail>;

  /**
   * 下载角色卡 PNG 字节(优先导入格式)。
   * 若 Provider 不提供 PNG,返回 null,调用方回退到 downloadJson。
   *
   * @param remoteId Provider 内部角色 ID
   * @returns PNG 字节或 null
   */
  downloadPng(remoteId: string): Promise<Uint8Array | null>;

  /**
   * 下载角色卡 JSON 字符串(Tavern Card V2/V3 格式)。
   *
   * @param remoteId Provider 内部角色 ID
   * @returns JSON 字符串
   */
  downloadJson(remoteId: string): Promise<string>;

  /**
   * 获取角色卡的来源页面 URL(用户可点击跳转到 Provider 站点)。
   *
   * @param remoteId Provider 内部角色 ID
   * @returns 来源页面 URL
   */
  getSourceUrl(remoteId: string): string;
}
