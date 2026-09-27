/**
 * BranchMapNode 分支缩进树的一行(2026-09-27 改版)
 *
 * 改版动机:原「176×118 方框 + 二维连线」的节点,在手机上分支一多就整张图难分辨。
 * 现改为缩进树(graph 风格)的一行:
 * - 去掉方框,用「拐角线 + 圆点 + 缩进」表达层级;
 * - 主路径(Root → 当前分支)的线与圆点用强调色,形成一条可见的脊线;
 * - 非主路径不再整体降透明度(那是"看不清"的来源),只用中性色画线;
 * - 标题 = 兄弟序号 + 分歧首句,一眼看出两条分支哪里不一样。
 *
 * 不依赖 Repository / Service / 页面实例;点击经回调上抛。
 */

import { BranchFlatRow } from '../models/BranchFlatRow';
import { formatRowTitle, formatRowHint } from '../utils/BranchTreeFlatten';
import { ThemePalette } from '../theme/ThemePalette';

/** 每层缩进宽度(vp) */
const INDENT_WIDTH: number = 16;
/** 本层拐角+圆点列宽度(vp) */
const ELBOW_WIDTH: number = 30;
/** 行高(vp) */
const ROW_HEIGHT: number = 52;
/** 行中线 y(vp) */
const ROW_CENTER: number = ROW_HEIGHT / 2;
/** 拐角竖线 x(vp) */
const ELBOW_LINE_X: number = 7;
/** 拐角横线长度(vp) */
const ELBOW_STUB_W: number = 12;

@Component
export struct BranchMapNode {
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 该行数据 */
  row: BranchFlatRow = createEmptyRow();
  /** 是否为用户选中(选中态不写进行数据,避免与 VM 状态重复持有) */
  @Prop isSelected: boolean = false;
  /** 点击回调 */
  onTap: (branchId: string) => void = (_: string) => {};

  build() {
    Row() {
      // 祖先层级竖线
      ForEach(this.row.ancestorRail, (hasRail: boolean) => {
        Stack() {
          if (hasRail) {
            Column()
              .width(1)
              .height(ROW_HEIGHT)
              .backgroundColor(this.railColor())
          }
        }
        .width(INDENT_WIDTH)
        .height(ROW_HEIGHT)
      }, (_item: boolean, index: number) => index.toString())

      // 本层拐角 + 圆点
      this.elbow()

      // 文案区:标题(序号 + 分歧首句) + 副标题(分叉轮次 · 消息数)
      Column() {
        Text(formatRowTitle(this.row))
          .fontSize(14)
          .fontWeight(this.row.isActive ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.titleColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(formatRowHint(this.row))
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 状态徽标
      if (this.row.isActive) {
        this.statusChip('当前')
      } else if (this.isSelected) {
        this.statusChip('已选择')
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ right: 12 })
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor(this.row.isActive
      ? $r('app.color.app_accent_surface')
      : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onTap(this.row.branchId);
    })
  }

  /** 本层拐角线 + 节点圆点 */
  @Builder
  elbow() {
    Stack() {
      if (this.row.depth > 0) {
        // 竖线:非最后子节点贯穿整行(├),最后子节点只到中线(└)
        Column()
          .width(1)
          .height(this.row.isLastChild ? ROW_CENTER : ROW_HEIGHT)
          .backgroundColor(this.railColor())
          .position({ x: ELBOW_LINE_X, y: 0 })

        // 横线
        Column()
          .width(ELBOW_STUB_W)
          .height(1)
          .backgroundColor(this.railColor())
          .position({ x: ELBOW_LINE_X, y: ROW_CENTER - 1 })
      }

      // 节点圆点(主路径实心强调色,其余空心中性色)
      Column()
        .width(this.dotSize())
        .height(this.dotSize())
        .borderRadius(this.dotSize())
        .border({ width: 2, color: this.dotColor() })
        .backgroundColor(this.row.isOnPath ? this.dotColor() : Color.Transparent)
        .position({
          x: this.row.depth > 0 ? ELBOW_LINE_X + ELBOW_STUB_W - 1 : 6,
          y: ROW_CENTER - this.dotSize() / 2
        })
    }
    .width(ELBOW_WIDTH)
    .height(ROW_HEIGHT)
  }

  /** 状态徽标(当前 / 已选择) */
  @Builder
  statusChip(label: string) {
    Text(label)
      .fontSize(10)
      .fontColor($r('app.color.app_on_accent'))
      .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
      .borderRadius(4)
      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
      .margin({ left: 6 })
  }

  private titleColor(): ResourceColor {
    if (this.row.isActive) {
      return ThemePalette.accentColor(this.effectiveTheme);
    }
    if (this.row.isEmpty) {
      return ThemePalette.textTertiaryColor(this.effectiveTheme);
    }
    return ThemePalette.textPrimaryColor(this.effectiveTheme);
  }

  /** 主路径用强调色,其余用分割线色(不再整体降透明度) */
  private railColor(): ResourceColor {
    return this.row.isOnPath
      ? ThemePalette.accentColor(this.effectiveTheme)
      : ThemePalette.dividerColor(this.effectiveTheme);
  }

  private dotColor(): ResourceColor {
    return this.railColor();
  }

  private dotSize(): number {
    return this.row.isOnPath ? 11 : 9;
  }
}

/**
 * 空行占位(@Prop 初始值用)。
 */
function createEmptyRow(): BranchFlatRow {
  return {
    branchId: '',
    depth: 0,
    isLastChild: true,
    ancestorRail: [],
    ordinalText: '',
    title: '',
    forkHint: '',
    messageCount: 0,
    isRoot: false,
    isActive: false,
    isEmpty: false,
    isOnPath: false
  };
}
