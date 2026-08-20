/**
 * MarketCharacterCard 市场角色卡列表项组件
 *
 * 双列等宽网格中的单张卡片,垂直布局:
 * - 顶部:封面图(4:5 比例,占满卡片宽度)
 * - 下方信息:角色名称 / 作者 / 简介 / 标签 / 元信息(来源/已导入/世界书/NSFW/更新时间)
 *
 * 设计要点:
 * - 双列卡片高度由 Grid 自动对齐(同一行取最高)
 * - 名称最多 2 行,作者 1 行,简介 2 行,标签 1 行截断
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
    Column() {
      if (this.item === null) {
        Row().width('100%').height(0)
      } else {
        // 顶部封面图(4:5 比例,占满宽度)
        Stack() {
          MarketCharacterAvatar({
            item: this.item,
            imgWidth: '100%',
            imgHeight: '100%',
            imgBorderRadius: 0,
            fallbackFontSize: 32,
            allowLoad: this.allowImageLoad
          })
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
            Text(this.item!.creator)
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
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
          }

          // 标签(单行截断,最多 3 个)
          if (this.resolveTags().length > 0) {
            this.tagsRow()
          }

          // 底部元信息行
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
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .clip(true)
    .onClick(() => {
      if (this.item !== null) {
        this.onPress({ item: this.item });
      }
    })
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
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
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
   * 元信息行:来源徽章 / 已导入 / 世界书 / NSFW / 更新时间。
   * Provider 名不翻译。
   */
  @Builder
  private metaRow(): void {
    Row() {
      // 来源徽章(Provider 名,不翻译)
      Text(this.item!.providerId)
        .fontSize(10)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 60 })

      // 已导入状态
      if (this.imported) {
        Text($r('app.string.market_already_imported'))
          .fontSize(10)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 4 })
      }

      // 世界书标记
      if (this.item!.hasCharacterBook) {
        Text($r('app.string.market_contains_lorebook'))
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 4 })
      }

      // NSFW 标记(国际通用简写,不翻译)
      if (this.item!.nsfw) {
        Text('NSFW')
          .fontSize(10)
          .fontColor($r('app.color.app_danger'))
          .backgroundColor('#FFE5E5')
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 4 })
      }

      Blank()

      // 更新时间(简短显示)
      if (this.item!.updatedAt > 0) {
        Text(this.formatDate(this.item!.updatedAt))
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
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
   * 格式化日期为 YYYY-MM-DD。
   */
  private formatDate(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const year: number = date.getFullYear();
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const monthStr: string = month < 10 ? '0' + month.toString() : month.toString();
    const dayStr: string = day < 10 ? '0' + day.toString() : day.toString();
    return year.toString() + '-' + monthStr + '-' + dayStr;
  }
}
