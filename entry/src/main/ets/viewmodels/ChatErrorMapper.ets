/**
 * ChatViewModel 错误映射纯函数
 *
 * 将服务层 / 底层抛出的原始错误信息收口映射为面向用户的中文提示。
 * 纯函数、无副作用（P3-1 自 ChatViewModel 逐字抽离）。
 */

/** 聊天主链路错误映射(发送 / 流式 / 重生成 / 代写 / 续写 / Swipe 等)。 */
export function toUserError(message: string): string {
  if (message.includes('No current provider config') || message.includes('尚未配置')) {
    return '尚未配置模型,请前往模型设置';
  }
  if (message.includes('disabled')) {
    return '当前模型已禁用,请前往模型设置';
  }
  if (message.includes('model name is empty') || message.includes('model name')) {
    return '模型名称未配置,请前往模型设置选择具体模型';
  }
  if (message.includes('API Key') || message.includes('api key') || message.includes('apiKey')) {
    return 'API Key 未配置,请前往模型设置';
  }
  if (message.includes('Authentication') || message.includes('401') || message.includes('Unauthorized')) {
    return '鉴权失败,请检查 API Key 是否正确';
  }
  if (message.includes('RateLimit') || message.includes('429')) {
    return '请求频率过高,请稍后重试';
  }
  if (message.includes('Timeout') || message.includes('timeout') || message.includes('超时')) {
    return '请求超时,请检查网络后重试';
  }
  if (message.includes('Network') || message.includes('connect') || message.includes('ECONNREFUSED')) {
    return '网络连接失败,请检查网络设置';
  }
  if (message.includes('Server') || message.includes('500') || message.includes('502') || message.includes('503')) {
    return '服务器错误,请稍后重试';
  }
  if (message.includes('Parse') || message.includes('parse') || message.includes('Invalid JSON')) {
    return '响应解析失败,请重试';
  }
  if (message.includes('Cancelled') || message.includes('cancel')) {
    return '已取消';
  }
  if (message.includes('空回复')) {
    return '模型返回了空回复,请重试';
  }
  if (message.includes('disposed')) {
    return '页面已退出,请重新进入';
  }
  return '请求失败,请重试';
}

/** 会话操作错误映射(切换 / 新建 / 删除会话等)。 */
export function toSessionOpError(message: string): string {
  if (message.includes('请先停止当前回复')) {
    return '请先停止当前回复';
  }
  if (message.includes('会话操作进行中')) {
    return '操作进行中,请稍候';
  }
  if (message.includes('会话不存在') || message.includes('已删除')) {
    return '会话不存在或已删除';
  }
  if (message.includes('不属于当前聊天上下文')) {
    return '会话不属于当前上下文';
  }
  if (message.includes('会话 id 为空')) {
    return '会话 id 无效';
  }
  return '会话操作失败,请重试';
}
