/**
 * CardImpres 角色卡「代写方向」扩展（arktavern-card-extensions）
 *
 * 读取 extensions.arktavern.impres.direction —— 由制卡工具（Card Studio）或卡作者生成，
 * 供聊天页「🎭代写」在生成候选发言时作为背景与剧情方向注入（不进入主对话 PromptBuilder）。
 *
 * 约束：
 * - 不依赖 ArkUI / ViewModel / 网络层 / 数据库
 * - 无声明 / 类型非法 / 空串（含纯空白）→ 返回空字符串（代写回退原有行为）
 */

/**
 * 从角色卡 extensions 中提取代写方向。
 *
 * 路径：extensions.arktavern.impres.direction
 * - extensions 无 arktavern / arktavern 非对象 → ''
 * - 无 impres / impres 非对象 → ''
 * - direction 非字符串 / 空串（含纯空白）→ ''
 */
export function extractImpresDirection(extensions: Record<string, Object>): string {
  const arktavern: Object | undefined = extensions['arktavern'];
  if (arktavern === undefined || !(arktavern instanceof Object)) {
    return '';
  }
  const ark: Record<string, Object> = arktavern as Record<string, Object>;
  const impres: Object | undefined = ark['impres'];
  if (impres === undefined || !(impres instanceof Object)) {
    return '';
  }
  const impresObj: Record<string, Object> = impres as Record<string, Object>;
  const direction: Object | undefined = impresObj['direction'];
  if (typeof direction !== 'string') {
    return '';
  }
  return (direction as string).trim();
}