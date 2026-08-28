/**
 * MarketCharacterCard 市场角色卡列表项组件
 *
 * 双列等宽网格中的单张卡片,垂直布局:
 * - 顶部:封面图(4:5 比例,占满卡片宽度)
 *   - 左上 NSFW 角标(危险色,半透明底)
 *   - 右上已导入角标(强调色)
 * - 下方信息:角色名称 / 作者 / 简介 / 标签 / 统计行(评分·下载量·日期)
 *
 * 设计要点:
 * - 使用 PressableCard 提供按压缩放反馈(0.98, 140ms)
 * - 名称最多 2 行,作者 1 行,简介 2 行,标签 1 行截断
 * - 信息层级:名称(primary/Medium) > 作者(secondary) > 简介(tertiary) > 统计(tertiary/小字)
 * - 英文长单词使用 textOverflow + constraintSize 防止撑出卡片
 * - 翻译开启时,显示翻译后的 name/summary/tags;不翻译 creator/providerId
 * - NSFW 未确认前 allowImageLoad=false,不发起图片加载
 * - 点击区域覆盖整张卡片
 *
 * 不直接:
 * - 发起网络请求(头像由 Image 组件自行加载)
 * - 调用 Service / Repository
 * - 修改 ViewModel 状态(通过 onPress 回调通知调用方)
 */

import { MarketCharacter } from '../models/MarketCharacter';
import { MarketCharacterAvatar } from './MarketCharacterAvatar';
import { PressableCard } from './PressableCard';
import { MarketTranslationResult } from '../models/MarketTranslation';
import { ThemePalette } from '../theme/ThemePalette';

/** 卡片点击参数 */
export interface MarketCardClickParams {
  item: MarketCharacter;
}

@Component
export struct MarketCharacterCard {
  /** 市场角色数据 */
  item: MarketCharacter | null = null;
  /** 是否已导入(由 ViewModel 通过 importedMap 判断后传入) */
  imported: boolean = false;
  /** 翻译结果(null 表示显示原文) */
  translation: MarketTranslationResult | null = null;
  /** 是否允许加载头像大图(NSFW 未确认前 false,避免预加载敏感内容) */
  allowImageLoad: boolean = true;
  /** 点击回调 */
  onPress: (params: MarketCardClickParams) => void = (_: MarketCardClickParams) => {};
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build(): void {
    if (this.item === null) {
      Row().width('100%').height(0)
    } else {
      PressableCard({
        onPress: (): void => {
          if (this.item !== null) {
            this.onPress({ item: this.item });
          }
        },
        content: (): void => {
          this.cardContent()
        }
      })
    }
  }

  /** 卡片内容(封面 + 信息区) */
  @Builder
  private cardContent(): void {
    Column() {
      // 顶部封面图(4:5 比例,占满宽度)
      Stack({ alignContent: Alignment.TopStart }) {
        MarketCharacterAvatar({
          item: this.item,
          imgWidth: '100%',
          imgHeight: '100%',
          imgBorderRadius: 0,
          fallbackFontSize: 32,
          allowLoad: this.allowImageLoad
        })

        // 封面顶部角标行:左上 NSFW / 右上已导入
        Row() {
          if (this.item!.nsfw) {
            Text('NSFW')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.app_danger'))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }

          Blank()

          if (this.imported) {
            Text($r('app.string.market_already_imported'))
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        .width('100%')
        .padding(6)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .aspectRatio(0.8)
      .clip(true)

      // 信息区
      Column() {
        // 角色名称(最多 2 行)
        Text(this.resolveName())
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 作者(最多 1 行,不翻译 creator 用户名)
        if (this.item!.creator.length > 0) {
          Text('@' + this.item!.creator)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
        }

        // 简介(最多 2 行)
        if (this.resolveSummary().length > 0) {
          Text(this.resolveSummary())
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
            .width('100%')
        }

        // 标签(单行截断,最多 3 个)
        if (this.resolveTags().length > 0) {
          this.tagsRow()
        }

        // 底部统计行:评分 / 下载量 / 世界书 / 更新时间
        this.metaRow()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: $r('app.float.app_spacing_8'),
        right: $r('app.float.app_spacing_8'),
        top: $r('app.float.app_spacing_8'),
        bottom: $r('app.float.app_spacing_8')
      })
    }
    .width('100%')
    .clip(true)
    .borderRadius($r('app.float.app_radius_md'))
  }

  /**
   * 标签行(最多 3 个,单行截断)。
   * 使用 Row + clip(true) 防止溢出。
   * 每个标签限制 maxWidth,避免单个长标签撑坏布局。
   */
  @Builder
  private tagsRow(): void {
    Row() {
      ForEach(this.takeFirstTags(), (tag: string, index: number) => {
        Text(tag)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ right: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 90 })
      }, (tag: string, index: number) => tag + '|' + index.toString())
    }
    .width('100%')
    .margin({ top: 4 })
    .clip(true)
  }

  /**
   * 底部统计行:世界书标记 + 评分/下载量/更新时间。
   * 评分与下载量为数据格式化(非本地化文案),-1 表示无数据不展示。
   */
  @Builder
  private metaRow(): void {
    Row() {
      // 世界书标记
      if (this.item!.hasCharacterBook) {
        Text($r('app.string.market_contains_lorebook'))
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      }

      Blank()

      // 统计信息(评分 · 下载量 · 日期)
      if (this.resolveStatsText().length > 0) {
        Text(this.resolveStatsText())
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 140 })
      }
    }
    .width('100%')
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 解析显示名称(翻译优先,无翻译显示原文)。
   */
  private resolveName(): string {
    if (this.item === null) {
      return '';
    }
    if (this.translation !== null && this.translation!.name.length > 0) {
      return this.translation!.name;
    }
    return this.item!.name;
  }

  /**
   * 解析显示简介。
   */
  private resolveSummary(): string {
    if (this.item === null) {
      return '';
    }
    if (this.translation !== null && this.translation!.summary.length > 0) {
      return this.translation!.summary;
    }
    return this.item!.summary;
  }

  /**
   * 解析显示标签。
   */
  private resolveTags(): string[] {
    if (this.item === null) {
      return [];
    }
    if (this.translation !== null && this.translation!.tags.length > 0) {
      return this.translation!.tags;
    }
    return this.item!.tags;
  }

  /**
   * 取前 3 个标签(避免标签过多挤压卡片高度)。
   */
  private takeFirstTags(): string[] {
    const tags: string[] = this.resolveTags();
    if (tags.length <= 3) {
      return tags;
    }
    const result: string[] = [];
    for (let i = 0; i < 3; i++) {
      result.push(tags[i]);
    }
    return result;
  }

  /**
   * 拼接统计行文本:★评分 · 下载量 · 更新日期。
   * 各字段无数据(<=0)时跳过。
   */
  private resolveStatsText(): string {
    if (this.item === null) {
      return '';
    }
    const parts: string[] = [];
    if (this.item!.rating > 0) {
      parts.push('★ ' + this.formatRating(this.item!.rating));
    }
    if (this.item!.downloadCount > 0) {
      parts.push(this.formatCount(this.item!.downloadCount));
    }
    if (this.item!.updatedAt > 0) {
      parts.push(this.formatDate(this.item!.updatedAt));
    }
    return parts.join(' · ');
  }

  /**
   * 格式化评分(保留 1 位小数)。
   */
  private formatRating(rating: number): string {
    return rating.toFixed(1);
  }

  /**
   * 格式化下载量(k / M 缩写)。
   */
  private formatCount(count: number): string {
    if (count >= 1000000) {
      return (count / 1000000).toFixed(1) + 'M';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1) + 'k';
    }
    return count.toString();
  }

  /**
   * 格式化日期为 MM-DD(年份信息密度低,卡片内省略)。
   */
  private formatDate(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const monthStr: string = month < 10 ? '0' + month.toString() : month.toString();
    const dayStr: string = day < 10 ? '0' + day.toString() : day.toString();
    return monthStr + '-' + dayStr;
  }
}
