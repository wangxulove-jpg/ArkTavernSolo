/**
 * BranchFlatRow 分支缩进树的一行(2026-09-27 分支地图改版)
 *
 * 取代原「二维画布 + 方框节点」的呈现:把分支树拍平成可滚动的缩进行序列,
 * 每行携带绘制拐角线/圆点与文案所需的全部信息,页面不再做布局计算。
 *
 * 纯展示数据,不依赖 ArkUI / Repository / Service。
 */

export interface BranchFlatRow {
  /** 对应 Branch ID(同时作为列表 key) */
  readonly branchId: string;
  /** 缩进层级(Root = 0) */
  readonly depth: number;
  /** 本行是否为父节点的最后一个子节点(决定拐角用 └ 还是 ├) */
  readonly isLastChild: boolean;
  /**
   * 祖先各层是否仍有后续兄弟。
   * 索引 i 对应深度 i 的祖先:true 表示该层还要继续向下画竖线。
   */
  readonly ancestorRail: boolean[];
  /** 兄弟序号标记(①②…);父节点只有一个子分支时为空字符串 */
  readonly ordinalText: string;
  /** 行标题:Root = "对话开始";非 Root = 与上一分支的分歧首句(无分歧内容 = "尚无新内容") */
  readonly title: string;
  /** 副标题前缀:"第 N 轮分叉";Root 为空字符串 */
  readonly forkHint: string;
  /** 该分支的消息数 */
  readonly messageCount: number;
  /** 是否为根分支 */
  readonly isRoot: boolean;
  /** 是否为当前 Active 分支(= 用户当前位置) */
  readonly isActive: boolean;
  /** 是否为"在分叉点之后没有任何新内容"的空分支 */
  readonly isEmpty: boolean;
  /** 是否位于 Root → Active 的路径上(用于把主路径画成一条粗脊线) */
  readonly isOnPath: boolean;
}
