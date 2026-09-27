/**
 * BranchTreeFlatten 分支树拍平工具(2026-09-27 分支地图改版)
 *
 * 把 BranchMapDisplayInfo[] 的分支树按 DFS 拍平成缩进树行序列,
 * 供页面用 List + 缩进行渲染(取代原二维画布布局)。
 *
 * 命名口径(修复原「第 N 轮分支」同名问题):
 * - 同一父分支下有多个子分支时,按 createdAt 升序给 ①②③ 序号,保证肉眼可区分;
 * - 行标题用"分歧首句"(firstDivergentAssistantPreview)——即"这条分支从哪开始不一样";
 * - 分叉点轮次降级为副标题前缀(第 N 轮分叉),不再当主标题;
 * - 分叉点之后没有任何新内容的分支标记 isEmpty(标题显示"尚无新内容")。
 *
 * 纯函数,不依赖 ArkUI / Repository / Service。
 */

import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchFlatRow } from '../models/BranchFlatRow';

/** 兄弟序号标记(超过 10 个回退为 (11) 形式) */
const ORDINAL_MARKS: string[] = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];

function ordinalMark(index: number): string {
  if (index >= 0 && index < ORDINAL_MARKS.length) {
    return ORDINAL_MARKS[index];
  }
  return '(' + (index + 1).toString() + ')';
}

/**
 * 取父分支 ID(无父或父不在集合内时返回空字符串)。
 */
function parentIdOf(info: BranchMapDisplayInfo, byId: Map<string, BranchMapDisplayInfo>): string {
  const pid: string | undefined = info.parentBranchId;
  if (pid === undefined || pid.length === 0) {
    return '';
  }
  return byId.has(pid) ? pid : '';
}

function byCreatedAt(a: BranchMapDisplayInfo, b: BranchMapDisplayInfo): number {
  return a.createdAt - b.createdAt;
}

/**
 * DFS 递归:把 node 及其子树按顺序压入 out。
 *
 * @param ancestorRail 祖先各层是否仍有后续兄弟(长度 = depth)
 * @param siblingIndex 在本层兄弟中的序号(0 起)
 * @param siblingCount 本层兄弟总数
 */
function walk(
  node: BranchMapDisplayInfo,
  depth: number,
  isLastChild: boolean,
  ancestorRail: boolean[],
  siblingIndex: number,
  siblingCount: number,
  childrenOf: Map<string, BranchMapDisplayInfo[]>,
  activeBranchId: string,
  onPathIds: Set<string>,
  out: BranchFlatRow[]
): void {
  const isEmpty: boolean = !node.isRoot && node.firstDivergentAssistantPreview.length === 0;
  let title: string = '对话开始';
  if (!node.isRoot) {
    title = isEmpty ? '尚无新内容' : node.firstDivergentAssistantPreview;
  }
  let forkHint: string = '';
  if (!node.isRoot) {
    forkHint = node.forkTurnNumber > 0
      ? '第 ' + node.forkTurnNumber.toString() + ' 轮分叉'
      : '分叉';
  }
  const row: BranchFlatRow = {
    branchId: node.branchId,
    depth: depth,
    isLastChild: isLastChild,
    ancestorRail: ancestorRail,
    ordinalText: siblingCount > 1 ? ordinalMark(siblingIndex) : '',
    title: title,
    forkHint: forkHint,
    messageCount: node.messageCount,
    isRoot: node.isRoot,
    isActive: node.branchId === activeBranchId,
    isEmpty: isEmpty,
    isOnPath: onPathIds.has(node.branchId)
  };
  out.push(row);

  const kids: BranchMapDisplayInfo[] = childrenOf.get(node.branchId) ?? [];
  for (let i = 0; i < kids.length; i++) {
    const nextRail: boolean[] = ancestorRail.slice();
    nextRail.push(!isLastChild);
    walk(kids[i], depth + 1, i === kids.length - 1, nextRail, i, kids.length,
      childrenOf, activeBranchId, onPathIds, out);
  }
}

/**
 * 把分支列表拍平成缩进树行序列。
 *
 * @param infos 展示信息列表(通常已按 createdAt 升序)
 * @param activeBranchId 当前 Active 分支 ID
 * @param onPathIds Root → Active 路径上的分支 ID 集合
 * @returns 按 DFS 顺序排列的行序列(空数组表示无分支)
 */
export function flattenBranchTree(
  infos: BranchMapDisplayInfo[],
  activeBranchId: string,
  onPathIds: Set<string>
): BranchFlatRow[] {
  const byId: Map<string, BranchMapDisplayInfo> = new Map<string, BranchMapDisplayInfo>();
  for (let i = 0; i < infos.length; i++) {
    byId.set(infos[i].branchId, infos[i]);
  }

  const childrenOf: Map<string, BranchMapDisplayInfo[]> = new Map<string, BranchMapDisplayInfo[]>();
  const roots: BranchMapDisplayInfo[] = [];
  for (let i = 0; i < infos.length; i++) {
    const info: BranchMapDisplayInfo = infos[i];
    const pid: string = parentIdOf(info, byId);
    if (pid.length === 0) {
      roots.push(info);
      continue;
    }
    const bucket: BranchMapDisplayInfo[] = childrenOf.get(pid) ?? [];
    bucket.push(info);
    childrenOf.set(pid, bucket);
  }

  roots.sort(byCreatedAt);
  childrenOf.forEach((bucket: BranchMapDisplayInfo[]): void => {
    bucket.sort(byCreatedAt);
  });

  const out: BranchFlatRow[] = [];
  for (let i = 0; i < roots.length; i++) {
    walk(roots[i], 0, true, [], i, roots.length, childrenOf, activeBranchId, onPathIds, out);
  }
  return out;
}

/**
 * 行标题文本:有兄弟序号时前缀序号,便于区分同一分叉点下的多条备选。
 * 节点组件与底部摘要栏共用,避免两处各写一份格式。
 */
export function formatRowTitle(row: BranchFlatRow): string {
  if (row.ordinalText.length === 0) {
    return row.title;
  }
  return row.ordinalText + ' ' + row.title;
}

/**
 * 行副标题文本:分叉轮次 + 消息数;空分支标注"尚无新内容"。
 */
export function formatRowHint(row: BranchFlatRow): string {
  const count: string = row.messageCount.toString() + ' 条消息';
  if (row.isRoot) {
    return '主分支 · ' + count;
  }
  const head: string = row.forkHint.length > 0 ? row.forkHint : '分叉';
  if (row.isEmpty) {
    return head + ' · 尚无新内容';
  }
  return head + ' · ' + count;
}
