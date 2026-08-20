/**
 * ProviderType AI 服务商类型枚举
 *
 * 定义支持的 AI Provider 类型。
 * 本阶段正式业务只准备 OpenAI-compatible。
 * 其他类型仅作为模型定义,不实现对应网络适配器。
 *
 * 安全要求:
 * - 枚举中不硬编码 Base URL 或服务商域名
 * - 枚举中不包含 API Key 或鉴权信息
 */

/**
 * AI Provider 类型枚举。
 */
export enum ProviderType {
  /** OpenAI 兼容接口(通用,适用于任何兼容 OpenAI API 的服务) */
  OpenAICompatible = 'OpenAICompatible',
  /** OpenAI 官方 */
  OpenAI = 'OpenAI',
  /** DeepSeek */
  DeepSeek = 'DeepSeek',
  /** 小米 MiMo */
  MiMo = 'MiMo',
  /** OpenRouter */
  OpenRouter = 'OpenRouter',
  /** Anthropic Claude */
  Claude = 'Claude',
  /** Google Gemini */
  Gemini = 'Gemini',
  /** OpenCode Go (OpenCode Zen Go 订阅网关) */
  OpenCodeGo = 'OpenCodeGo',
  /** 硅基流动 SiliconFlow (OpenAI 兼容推理云) */
  SiliconFlow = 'SiliconFlow'
}
