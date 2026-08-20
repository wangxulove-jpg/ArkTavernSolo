/**
 * ProviderPreset Provider 预设数据模型
 *
 * 定义各 Provider 的预设配置,包括默认 Base URL、可用模型列表等。
 * 页面只消费预设数据,不把预设保存到 Preferences。
 * 不包含 API Key 或任何敏感信息。
 *
 * 当前完整实现:DeepSeek、MiMo
 * 后续可扩展:OpenAI、OpenRouter
 * OpenAI Compatible 继续使用自定义模式(无预设)。
 */

import { ProviderType } from './ProviderType';

/**
 * 模型选项。
 */
export interface ModelOption {
  /** 模型标识(保存到 ProviderConfig.modelName) */
  readonly id: string;
  /** 显示名称 */
  readonly displayName: string;
  /** 简要描述(可选) */
  readonly description?: string;
}

/**
 * Provider 预设配置。
 */
export interface ProviderPreset {
  /** Provider 类型 */
  readonly providerType: ProviderType;
  /** 显示名称 */
  readonly displayName: string;
  /** 默认 Base URL */
  readonly defaultBaseUrl: string;
  /** 可用模型列表 */
  readonly availableModels: ModelOption[];
  /** 默认模型 */
  readonly defaultModel: ModelOption;
}

/**
 * 获取 Provider 的预设配置,不存在则返回 null。
 */
export function getPreset(type: ProviderType): ProviderPreset | null {
  for (let i = 0; i < ALL_PRESETS.length; i++) {
    if (ALL_PRESETS[i].providerType === type) {
      return ALL_PRESETS[i];
    }
  }
  return null;
}

/**
 * 判断 Provider 是否有预设。
 */
export function hasPreset(type: ProviderType): boolean {
  return getPreset(type) !== null;
}

// ===== DeepSeek 预设 =====

const DEEPSEEK_MODELS: ModelOption[] = [
  {
    id: 'deepseek-v4-flash',
    displayName: 'DeepSeek V4 Flash',
    description: '快速响应,适合日常对话(1M 上下文)'
  },
  {
    id: 'deepseek-v4-pro',
    displayName: 'DeepSeek V4 Pro',
    description: '深度推理旗舰,复杂任务与长上下文(1M 上下文)'
  }
];

const DEEPSEEK_PRESET: ProviderPreset = {
  providerType: ProviderType.DeepSeek,
  displayName: 'DeepSeek',
  // 直接设置完整端点,避免 OpenAiUrlBuilder 追加 /v1
  defaultBaseUrl: 'https://api.deepseek.com/chat/completions',
  availableModels: DEEPSEEK_MODELS,
  defaultModel: DEEPSEEK_MODELS[0]
};

// ===== MiMo 预设 =====

const MIMO_MODELS: ModelOption[] = [
  {
    id: 'mimo-v2.5-pro',
    displayName: 'MiMo V2.5 Pro',
    description: '旗舰推理模型,复杂任务与长程 Agent(1M 上下文)'
  },
  {
    id: 'mimo-v2.5',
    displayName: 'MiMo V2.5',
    description: '多模态理解,支持文本/图像/视频/音频(1M 上下文)'
  }
];

const MIMO_PRESET: ProviderPreset = {
  providerType: ProviderType.MiMo,
  displayName: 'MiMo',
  // 直接设置完整端点,避免 OpenAiUrlBuilder 追加 /v1
  defaultBaseUrl: 'https://api.xiaomimimo.com/v1/chat/completions',
  availableModels: MIMO_MODELS,
  defaultModel: MIMO_MODELS[0]
};

// ===== OpenCode Go 预设 =====

const OPENCODE_GO_MODELS: ModelOption[] = [
  {
    id: 'deepseek-v4-flash',
    displayName: 'DeepSeek V4 Flash',
    description: '快速响应,OpenCode Go 网关转发(1M 上下文)'
  },
  {
    id: 'deepseek-v4-pro',
    displayName: 'DeepSeek V4 Pro',
    description: '深度推理旗舰,OpenCode Go 网关转发(1M 上下文)'
  },
  {
    id: 'glm-5.2',
    displayName: 'GLM-5.2',
    description: '智谱 GLM,长上下文(1M 上下文)'
  },
  {
    id: 'glm-5.1',
    displayName: 'GLM-5.1',
    description: '智谱 GLM 推理模型(200K 上下文)'
  },
  {
    id: 'hy3',
    displayName: 'Hy3',
    description: '推理模型(256K 上下文)'
  },
  {
    id: 'kimi-k2.7-code',
    displayName: 'Kimi K2.7 Code',
    description: '月之暗面 Kimi,代码向(262K 上下文)'
  },
  {
    id: 'kimi-k2.6',
    displayName: 'Kimi K2.6',
    description: '月之暗面 Kimi 推理(256K 上下文)'
  },
  {
    id: 'kimi-k3',
    displayName: 'Kimi K3',
    description: '月之暗面 Kimi 旗舰(约 1M 上下文,2 倍用量)'
  },
  {
    id: 'mimo-v2.5-pro',
    displayName: 'MiMo V2.5 Pro',
    description: '小米 MiMo 旗舰推理(约 1M 上下文)'
  },
  {
    id: 'mimo-v2.5',
    displayName: 'MiMo V2.5',
    description: '小米 MiMo 多模态(1M 上下文)'
  },
  {
    id: 'minimax-m2.7',
    displayName: 'MiniMax-M2.7',
    description: 'MiniMax 推理模型(204K 上下文)'
  },
  {
    id: 'qwen3.6-plus',
    displayName: 'Qwen3.6 Plus',
    description: '通义千问 Qwen,长上下文(1M 上下文)'
  }
];

const OPENCODE_GO_PRESET: ProviderPreset = {
  providerType: ProviderType.OpenCodeGo,
  displayName: 'OpenCode Go',
  // OpenAI 兼容端点,OpenAiUrlBuilder 会自动追加 /chat/completions
  defaultBaseUrl: 'https://opencode.ai/zen/go/v1',
  availableModels: OPENCODE_GO_MODELS,
  defaultModel: OPENCODE_GO_MODELS[0]
};

// ===== SiliconFlow 预设 =====

const SILICONFLOW_MODELS: ModelOption[] = [
  {
    id: 'deepseek-ai/DeepSeek-V4-Flash',
    displayName: 'DeepSeek V4 Flash',
    description: 'DeepSeek 旗舰 MoE(1M 上下文)'
  },
  {
    id: 'deepseek-ai/DeepSeek-V4-Pro',
    displayName: 'DeepSeek V4 Pro',
    description: 'DeepSeek 旗舰推理(1M 上下文)'
  },
  {
    id: 'deepseek-ai/DeepSeek-V3.2',
    displayName: 'DeepSeek V3.2',
    description: 'DeepSeek V3.2(160K 上下文)'
  },
  {
    id: 'Pro/deepseek-ai/DeepSeek-V3.2',
    displayName: 'DeepSeek V3.2 Pro',
    description: 'DeepSeek V3.2 Pro(160K 上下文)'
  },
  {
    id: 'Pro/deepseek-ai/DeepSeek-R1',
    displayName: 'DeepSeek R1 Pro',
    description: 'DeepSeek R1 推理(160K 上下文)'
  },
  {
    id: 'zai-org/GLM-5.2',
    displayName: 'GLM-5.2',
    description: '智谱 GLM 旗舰(1M 上下文)'
  },
  {
    id: 'Pro/zai-org/GLM-5.1',
    displayName: 'GLM-5.1 Pro',
    description: '智谱 GLM 旗舰(198K 上下文)'
  },
  {
    id: 'Qwen/Qwen3.5-397B-A17B',
    displayName: 'Qwen3.5 397B',
    description: '通义千问 MoE(256K 上下文)'
  },
  {
    id: 'Qwen/Qwen3.6-27B',
    displayName: 'Qwen3.6 27B',
    description: '通义千问(256K 上下文)'
  },
  {
    id: 'Pro/moonshotai/Kimi-K2.6',
    displayName: 'Kimi K2.6 Pro',
    description: '月之暗面 Kimi(256K 上下文)'
  },
  {
    id: 'moonshotai/Kimi-K2.7-Code',
    displayName: 'Kimi K2.7 Code',
    description: 'Kimi 代码向(256K 上下文)'
  },
  {
    id: 'MiniMaxAI/MiniMax-M2.5',
    displayName: 'MiniMax M2.5',
    description: 'MiniMax(192K 上下文)'
  }
];

const SILICONFLOW_PRESET: ProviderPreset = {
  providerType: ProviderType.SiliconFlow,
  displayName: '硅基流动',
  defaultBaseUrl: 'https://api.siliconflow.cn/v1',
  availableModels: SILICONFLOW_MODELS,
  defaultModel: SILICONFLOW_MODELS[0]
};

// ===== 全部预设列表 =====

const ALL_PRESETS: ProviderPreset[] = [
  DEEPSEEK_PRESET,
  MIMO_PRESET,
  OPENCODE_GO_PRESET,
  SILICONFLOW_PRESET
];