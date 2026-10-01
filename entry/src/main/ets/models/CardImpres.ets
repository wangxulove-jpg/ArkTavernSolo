/**
 * CardImpres 角色卡「代写方向」扩展（arktavern-card-extensions）
 *
 * 读取 extensions.arktavern.impres.direction —— 由制卡工具（Card Studio）或卡作者生成，
 * 供聊天页「🎭代写」在生成候选发言时作为背景与剧情方向注入（不进入主对话 PromptBuilder）；
 * 也可在 App 角色编辑页「代写」分段手写修改（applyImpresDirection）。
 *
 * 约束：
 * - 不依赖 ArkUI / ViewModel / 网络层 / 数据库
 * - 无声明 / 类型非法 / 空串（含纯空白）→ 返回空字符串（代写回退原有行为）
 */

const ARKTAVERN_KEY: string = 'arktavern';
const IMPRES_KEY: string = 'impres';
const DIRECTION_KEY: string = 'direction';

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

/**
 * 生成"写入/清除代写方向"后的新 extensions（不可变，不修改入参）。
 * - direction 非空：写入 extensions.arktavern.impres.direction（其余键原样保留）
 * - direction 为空（含纯空白）：移除 direction；若 impres 内已无其他键则一并移除 impres
 * - 顶层键与 arktavern / impres 下的其他键一律原样保留（arktavern 原非对象时按空对象重建）
 *
 * ArkTS 约束：禁 delete，故各处均为"重建对象 + 按需跳键"。
 */
export function applyImpresDirection(
  extensions: Record<string, Object>,
  direction: string
): Record<string, Object> {
  const trimmed: string = direction.trim();

  // 顶层：复制除 arktavern 外的全部键
  const result: Record<string, Object> = {};
  const topKeys: string[] = Object.keys(extensions);
  for (let i = 0; i < topKeys.length; i++) {
    const key: string = topKeys[i];
    if (key !== ARKTAVERN_KEY) {
      result[key] = extensions[key];
    }
  }

  const arkSource: Object | undefined = extensions[ARKTAVERN_KEY];
  const arkSourceValid: boolean = arkSource !== undefined && arkSource instanceof Object;
  const ark: Record<string, Object> = arkSourceValid
    ? arkSource as Record<string, Object>
    : {};

  // impres：复制除 direction 外的全部键，再按需写入新值
  const impresSource: Object | undefined = ark[IMPRES_KEY];
  const impresValid: boolean = impresSource !== undefined && impresSource instanceof Object;
  const impres: Record<string, Object> = impresValid
    ? impresSource as Record<string, Object>
    : {};
  const newImpres: Record<string, Object> = {};
  const impresKeys: string[] = Object.keys(impres);
  for (let i = 0; i < impresKeys.length; i++) {
    const key: string = impresKeys[i];
    if (key !== DIRECTION_KEY) {
      newImpres[key] = impres[key];
    }
  }
  if (trimmed.length > 0) {
    newImpres[DIRECTION_KEY] = trimmed;
  }

  // arktavern：复制除 impres 外的全部键，再按需写入新 impres
  const newArk: Record<string, Object> = {};
  const arkKeys: string[] = Object.keys(ark);
  for (let i = 0; i < arkKeys.length; i++) {
    const key: string = arkKeys[i];
    if (key !== IMPRES_KEY) {
      newArk[key] = ark[key];
    }
  }
  if (Object.keys(newImpres).length > 0) {
    newArk[IMPRES_KEY] = newImpres;
  }
  if (arkSourceValid || Object.keys(newArk).length > 0) {
    result[ARKTAVERN_KEY] = newArk;
  }
  return result;
}