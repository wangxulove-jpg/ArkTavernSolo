/**
 * BranchTreeLayout 分支树布局计算工具(T-6.4B-1.1 / T-6.4B-2-R1 / T-6.4B-4)
 *
 * 按 forkTurnNumber(对话轮次)分层布局,确保 Branch 在 BranchMap 中的 Y 位置
 * 严格对应 fork 发生的对话轮次位置:
 *
 * - Root: forkTurnNumber=0 → 顶部
 * - 从 U1 fork: forkTurnNumber=1 → 第 1 轮位置
 * - 从 U2 fork: forkTurnNumber=2 → 第 2 轮位置
 * - 从末尾 fork: forkTurnNumber=N → 最底部
 *
 * T-6.4B-3-R1 布局策略(子树居中于父节点):
 * - 旧版按 forkTurnNumber 分组 + 整组居中于画布,导致每个层级都"挤到中间"
 * - 新版按"子树居中于父节点"布局:
 *   - Root 居中于画布顶部
 *   - 每个 Branch 的子节点(直接 parentBranchId === this.id)以该 Branch 为中心横向排列
 *   - 从任何 fork 点向下分出的子分支,在视觉上始终位于该 fork 点正下方
 *   - 多兄弟分支横向并列,中心对齐父节点
 *   - 单子分支直接放在父节点正下方
 * - 这样从任何节点向下看,其所有后代都位于该节点正下方,整齐不挤到中间
 *
 * T-6.4B-4: Y 轴层级压缩
 * - 不再使用 forkTurnNumber × LEVEL_GAP 作为 Y 坐标
 * - 将所有节点的 forkTurnNumber 排序后压缩为连续的可视层级(0, 1, 2, ...)
 * - Y = TOP_PADDING + layer × (NODE_HEIGHT + VERTICAL_GAP)
 * - 同一轮次的多个分支共享同一层
 * - 子节点保证至少比父节点低一层
 * - 真实轮次通过节点文字显示,不再通过巨大空白表示
 *
 * 连接线逻辑(T-6.4B-2-R1 修正):
 * - 对每个 Branch,沿 parentBranchId 链向上查找,找到第一个
 *   forkTurnNumber < 当前 Branch forkTurnNumber 的祖先作为起点
 * - 保证所有连线都向下(低轮次 → 高轮次),无横向、无向上
 * - 同轮次的平行 Branch 之间不会有连线
 * - 从同一对话点 fork 出的多个 Branch 都会连到上方某个低 turn 祖先
 *
 * 不依赖 ArkUI / Repository / Service。
 */

import { ConversationBranchSummary } from '../models/ConversationBranch';
import {
  BranchMapNodeLayout,
  BranchTreeLayoutResult,
  BranchTreeEdge
} from '../models/BranchMapNodeLayout';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';

/** 节点固定宽度(vp) */
const NODE_WIDTH: number = 176;
/** 普通节点固定高度(vp) */
const NODE_HEIGHT: number = 118;
/** 末端节点高度(vp,比普通节点矮) */
const TERMINAL_NODE_HEIGHT: number = 88;
/** 兄弟节点之间的水平间距(vp) */
const SIBLING_GAP: number = 28;
/** 垂直间距(vp):相邻可视层级之间的间距(取代旧 LEVEL_GAP=140) */
const VERTICAL_GAP: number = 28;
/** 画布外围 padding(vp) */
const CANVAS_PADDING: number = 24;
/** 画布底部额外 padding */
const BOTTOM_PADDING: number = 32;

/**
 * 获取节点固定宽度。
 */
export function getNodeWidth(): number {
  return NODE_WIDTH;
}

/**
 * 获取节点固定高度。
 */
export function getNodeHeight(): number {
  return NODE_HEIGHT;
}

/**
 * 获取末端节点高度。
 */
export function getTerminalNodeHeight(): number {
  return TERMINAL_NODE_HEIGHT;
}

/**
 * 获取垂直间距。
 */
export function getVerticalGap(): number {
  return VERTICAL_GAP;
}

/**
 * 获取画布 padding。
 */
export function getCanvasPadding(): number {
  return CANVAS_PADDING;
}

/**
 * 构建层级排序键:同一轮次中,分叉节点在前,末端节点在后。
 * 按 forkTurnNumber(分叉轮次)而非 currentMaxTurn 排序,
 * 保证同一轮次分叉的分支共享同一可视层(Y 轴与对话位置对应)。
 */
function getLayerSortKey(info: BranchMapDisplayInfo): number {
  const typeOrder: number = info.isTerminal ? 1 : 0;
  return info.forkTurnNumber * 2 + typeOrder;
}

/**
 * 构建压缩层级映射:将真实轮次映射为连续的可视层级(0, 1, 2, ...)。
 * 同时保证子节点至少比父节点低一层,避免父子重叠。
 */
function buildLayerMap(infos: BranchMapDisplayInfo[]): Map<string, number> {
  // 收集所有唯一的排序键
  const sortKeys: number[] = [];
  const seenKeys: Set<number> = new Set<number>();
  for (let i = 0; i < infos.length; i++) {
    const key: number = getLayerSortKey(infos[i]);
    if (!seenKeys.has(key)) {
      seenKeys.add(key);
      sortKeys.push(key);
    }
  }
  sortKeys.sort((a: number, b: number): number => a - b);

  // 排序键 → 时间层级(0,1,2,...)
  const chronologicalRank: Map<number, number> = new Map<number, number>();
  for (let i = 0; i < sortKeys.length; i++) {
    chronologicalRank.set(sortKeys[i], i);
  }

  // 构造 nodeId → info 映射
  const nodeById: Map<string, BranchMapDisplayInfo> = new Map<string, BranchMapDisplayInfo>();
  for (let i = 0; i < infos.length; i++) {
    nodeById.set(infos[i].nodeId, infos[i]);
  }

  const result: Map<string, number> = new Map<string, number>();
  const resolving: Set<string> = new Set<string>();

  const resolveLayer = (info: BranchMapDisplayInfo): number => {
    const cached: number | undefined = result.get(info.nodeId);
    if (cached !== undefined) {
      return cached;
    }

    // 防止异常父子数据形成死循环
    if (resolving.has(info.nodeId)) {
      return 0;
    }
    resolving.add(info.nodeId);

    const sortKey: number = getLayerSortKey(info);
    const timeLayer: number = chronologicalRank.get(sortKey) ?? 0;
    let layer: number = timeLayer;

    // 如果有父节点,确保子节点至少比父节点低一层
    const parentId: string | undefined = info.parentBranchId;
    if (parentId !== undefined && parentId.length > 0) {
      const parent: BranchMapDisplayInfo | undefined = nodeById.get(parentId);
      if (parent !== undefined) {
        layer = Math.max(timeLayer, resolveLayer(parent) + 1);
      }
    }

    resolving.delete(info.nodeId);
    result.set(info.nodeId, layer);
    return layer;
  };

  for (let i = 0; i < infos.length; i++) {
    resolveLayer(infos[i]);
  }

  return result;
}

/**
 * 计算分支树布局(T-6.4B-3-R1 子树居中算法 / T-6.4B-4 层级压缩)。
 *
 * 算法步骤:
 * 1. 构造 children 映射(parentBranchId -> 直接子节点列表)
 * 2. 找到 Root(parentBranchId 为空)
 * 3. DFS 计算每个节点的 subtreeWidth(子树所需总宽度)
 * 4. DFS 分配 X/Y 坐标:
 *    - Y = CANVAS_PADDING + layer × (NODE_HEIGHT + VERTICAL_GAP)(压缩层级)
 *    - X = 子树左边界 + (subtreeWidth - NODE_WIDTH) / 2(节点居中于自己的子树)
 *    - 子节点依次排列在父节点的子树内,父节点居中
 * 5. 生成连接线(子节点 → 第一个 turn 更小的祖先)
 * 6. 计算画布尺寸
 *
 * @param branches 所有 Branch 摘要
 * @param displayInfos 含 forkTurnNumber 的展示信息
 * @returns 布局结果(节点位置 + 连接线 + 画布尺寸)
 */
export function computeBranchTreeLayout(
  branches: ConversationBranchSummary[],
  displayInfos: BranchMapDisplayInfo[]
): BranchTreeLayoutResult {
  if (branches.length === 0) {
    return {
      nodes: [],
      canvasWidth: CANVAS_PADDING * 2,
      canvasHeight: CANVAS_PADDING * 2,
      edges: []
    };
  }

  // 0. 构造 branchId → forkTurnNumber 映射
  const turnNumberMap: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < displayInfos.length; i++) {
    const info: BranchMapDisplayInfo = displayInfos[i];
    turnNumberMap.set(info.branchId, info.forkTurnNumber);
  }

  // 0.2 构建压缩层级映射
  const layerMap: Map<string, number> = buildLayerMap(displayInfos);

  // 1. 构造 children 映射(parentBranchId -> 直接子节点列表)
  const childrenMap: Map<string, ConversationBranchSummary[]> = new Map<string, ConversationBranchSummary[]>();
  const rootBranches: ConversationBranchSummary[] = [];
  for (let i = 0; i < branches.length; i++) {
    const summary: ConversationBranchSummary = branches[i];
    const parentId: string | undefined = summary.parentBranchId;
    if (parentId === undefined || parentId.length === 0) {
      rootBranches.push(summary);
    } else {
      let children: ConversationBranchSummary[] | undefined = childrenMap.get(parentId);
      if (children === undefined) {
        children = [];
        childrenMap.set(parentId, children);
      }
      children.push(summary);
    }
  }

  // 2. 每个 children 数组按 createdAt 升序排序(稳定布局)
  const childrenKeys: string[] = Array.from(childrenMap.keys());
  for (let i = 0; i < childrenKeys.length; i++) {
    const children: ConversationBranchSummary[] | undefined = childrenMap.get(childrenKeys[i]);
    if (children === undefined) {
      continue;
    }
    children.sort((a: ConversationBranchSummary, b: ConversationBranchSummary): number => {
      return a.createdAt - b.createdAt;
    });
  }
  rootBranches.sort((a: ConversationBranchSummary, b: ConversationBranchSummary): number => {
    return a.createdAt - b.createdAt;
  });

  // 3. DFS 计算每个节点的 subtreeWidth
  const subtreeWidthMap: Map<string, number> = new Map<string, number>();

  const computeSubtreeWidth = (branchId: string): number => {
    const existing: number | undefined = subtreeWidthMap.get(branchId);
    if (existing !== undefined) {
      return existing;
    }
    const children: ConversationBranchSummary[] | undefined = childrenMap.get(branchId);
    if (children === undefined || children.length === 0) {
      const w: number = NODE_WIDTH;
      subtreeWidthMap.set(branchId, w);
      return w;
    }
    let total: number = 0;
    for (let i = 0; i < children.length; i++) {
      total += computeSubtreeWidth(children[i].id);
    }
    total += (children.length - 1) * SIBLING_GAP;
    const w: number = total > NODE_WIDTH ? total : NODE_WIDTH;
    subtreeWidthMap.set(branchId, w);
    return w;
  };

  for (let i = 0; i < branches.length; i++) {
    computeSubtreeWidth(branches[i].id);
  }

  // 4. DFS 分配 X/Y 坐标
  //    - Y = CANVAS_PADDING + layer × (NODE_HEIGHT + VERTICAL_GAP)(压缩层级)
  //    - X = leftX + (subtreeWidth - NODE_WIDTH) / 2
  const layoutMap: Map<string, BranchMapNodeLayout> = new Map<string, BranchMapNodeLayout>();
  const nodes: BranchMapNodeLayout[] = [];
  let maxLayer: number = 0;

  const layoutNode = (branch: ConversationBranchSummary, leftX: number, depth: number): void => {
    const subtreeWidth: number = subtreeWidthMap.get(branch.id) ?? NODE_WIDTH;
    const turnNum: number | undefined = turnNumberMap.get(branch.id);
    const turn: number = turnNum !== undefined ? turnNum : 0;

    // 查找对应的 displayInfo 以获取 nodeId 和层级
    const displayInfo: BranchMapDisplayInfo | undefined = displayInfos.find(
      (info: BranchMapDisplayInfo): boolean => info.branchId === branch.id && !info.isTerminal
    );
    const nodeId: string = displayInfo !== undefined ? displayInfo.nodeId : branch.id;
    const layer: number = layerMap.get(nodeId) ?? 0;
    if (layer > maxLayer) {
      maxLayer = layer;
    }

    const y: number = CANVAS_PADDING + layer * (NODE_HEIGHT + VERTICAL_GAP);
    const x: number = leftX + (subtreeWidth - NODE_WIDTH) / 2;

    const children: ConversationBranchSummary[] | undefined = childrenMap.get(branch.id);
    const siblingCount: number = children !== undefined ? children.length : 0;
    const isTerminalBranch: boolean = displayInfo !== undefined ? displayInfo.isTerminal : false;
    const nodeHeight: number = isTerminalBranch ? TERMINAL_NODE_HEIGHT : NODE_HEIGHT;

    const layout: BranchMapNodeLayout = {
      nodeId: nodeId,
      branchId: branch.id,
      parentBranchId: branch.parentBranchId !== undefined
        ? branch.parentBranchId : '',
      depth: depth,
      forkTurnNumber: turn,
      currentMaxTurn: turn,
      x: x,
      y: y,
      width: NODE_WIDTH,
      height: nodeHeight,
      siblingIndex: 0,
      siblingCount: siblingCount,
      isTerminal: displayInfo !== undefined ? displayInfo.isTerminal : false,
      isCurrent: displayInfo !== undefined ? displayInfo.isCurrent : false
    };
    nodes.push(layout);
    layoutMap.set(layout.branchId, layout);

    // 递归布局子节点
    if (children !== undefined && children.length > 0) {
      let childLeftX: number = leftX;
      for (let i = 0; i < children.length; i++) {
        const child: ConversationBranchSummary = children[i];
        const childSubtreeWidth: number = subtreeWidthMap.get(child.id) ?? NODE_WIDTH;
        layoutNode(child, childLeftX, depth + 1);
        childLeftX += childSubtreeWidth + SIBLING_GAP;
      }
    }
  };

  // 从所有 Root 开始布局
  let currentLeftX: number = CANVAS_PADDING;
  for (let i = 0; i < rootBranches.length; i++) {
    const root: ConversationBranchSummary = rootBranches[i];
    const rootSubtreeWidth: number = subtreeWidthMap.get(root.id) ?? NODE_WIDTH;
    layoutNode(root, currentLeftX, 0);
    currentLeftX += rootSubtreeWidth + SIBLING_GAP;
  }

  // 5. 生成 edges(连到直接父节点,保证连线与节点层级一一对应且始终向下)
  const edges: BranchTreeEdge[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const nodeLayout: BranchMapNodeLayout = nodes[i];
    if (nodeLayout.parentBranchId.length === 0) {
      continue;
    }
    const parentLayout: BranchMapNodeLayout | undefined =
      layoutMap.get(nodeLayout.parentBranchId);
    if (parentLayout === undefined) {
      continue;
    }
    if (parentLayout.nodeId === nodeLayout.nodeId) {
      continue;
    }
    edges.push({
      parentBranchId: parentLayout.branchId,
      childBranchId: nodeLayout.branchId,
      childNodeId: nodeLayout.nodeId,
      startX: parentLayout.x + parentLayout.width / 2,
      startY: parentLayout.y + parentLayout.height,
      endX: nodeLayout.x + nodeLayout.width / 2,
      endY: nodeLayout.y
    });
  }

  // 6. 计算画布尺寸
  let totalRootWidth: number = 0;
  for (let i = 0; i < rootBranches.length; i++) {
    const w: number = subtreeWidthMap.get(rootBranches[i].id) ?? NODE_WIDTH;
    totalRootWidth += w;
  }
  if (rootBranches.length > 1) {
    totalRootWidth += (rootBranches.length - 1) * SIBLING_GAP;
  }
  const contentWidth: number = Math.max(totalRootWidth + CANVAS_PADDING * 2, NODE_WIDTH + CANVAS_PADDING * 2);

  const contentHeight: number = CANVAS_PADDING
    + (maxLayer + 1) * (NODE_HEIGHT + VERTICAL_GAP)
    + BOTTOM_PADDING;

  return {
    nodes: nodes,
    canvasWidth: contentWidth,
    canvasHeight: contentHeight,
    edges: edges
  };
}