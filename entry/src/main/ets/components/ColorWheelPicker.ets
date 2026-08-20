/**
 * ColorWheelPicker HSV 色盘颜色选择器
 *
 * 职责:
 * - 提供可视化的 HSV 颜色选择(饱和度/明度二维区域 + 色相条)
 * - 用户拖动/点击即可选色,无需手动输入 RGB / Hex 数字
 * - 实时回调 onColorChange 把选中的 #RRGGBB 传给调用方
 *
 * 不负责:
 * - 颜色持久化(由调用方负责)
 * - 预设色块(由调用方在外层提供)
 *
 * 使用方式:
 *   ColorWheelPicker({
 *     color: '#5B7CFA',
 *     onChange: (c: string): void => { ... }
 *   })
 */

import { ThemePalette } from '../theme/ThemePalette';

/** 将 0~1 夹取到 [0, 1] */
function clamp01(v: number): number {
  if (v < 0) {
    return 0;
  }
  if (v > 1) {
    return 1;
  }
  return v;
}

/** 将 0~255 整数转为两位大写十六进制 */
function toHex2(v: number): string {
  const c: number = Math.max(0, Math.min(255, Math.round(v)));
  const s: string = c.toString(16).toUpperCase();
  return s.length === 1 ? '0' + s : s;
}

/** '#RRGGBB' 转为 [r, g, b]。非法输入回退红色。 */
function hexToRgb(hex: string): [number, number, number] {
  let h: string = hex;
  if (h.length > 0 && h.charAt(0) === '#') {
    h = h.substring(1);
  }
  if (h.length === 3) {
    h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
  }
  if (h.length !== 6) {
    return [255, 0, 0];
  }
  const r: number = parseInt(h.substring(0, 2), 16);
  const g: number = parseInt(h.substring(2, 4), 16);
  const b: number = parseInt(h.substring(4, 6), 16);
  if (isNaN(r) || isNaN(g) || isNaN(b)) {
    return [255, 0, 0];
  }
  return [r, g, b];
}

/** [r, g, b] 转为 '#RRGGBB' */
function rgbToHex(r: number, g: number, b: number): string {
  return '#' + toHex2(r) + toHex2(g) + toHex2(b);
}

/** HSV 直接转为 '#RRGGBB' */
function hsvToHex(h: number, s: number, v: number): string {
  const rgb: [number, number, number] = hsvToRgb(h, s, v);
  return rgbToHex(rgb[0], rgb[1], rgb[2]);
}

/** HSV(h:0-360, s:0-100, v:0-100) 转为 [r, g, b] */
function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
  const sn: number = clamp01(s / 100);
  const vn: number = clamp01(v / 100);
  const hh: number = ((h % 360) + 360) % 360;
  const c: number = vn * sn;
  const x: number = c * (1 - Math.abs((hh / 60) % 2 - 1));
  const m: number = vn - c;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (hh < 60) {
    r = c; g = x; b = 0;
  } else if (hh < 120) {
    r = x; g = c; b = 0;
  } else if (hh < 180) {
    r = 0; g = c; b = x;
  } else if (hh < 240) {
    r = 0; g = x; b = c;
  } else if (hh < 300) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}

/** [r, g, b] 转为 HSV(h:0-360, s:0-100, v:0-100) */
function rgbToHsv(r: number, g: number, b: number): [number, number, number] {
  const rn: number = r / 255;
  const gn: number = g / 255;
  const bn: number = b / 255;
  const max: number = Math.max(rn, gn, bn);
  const min: number = Math.min(rn, gn, bn);
  const d: number = max - min;
  let h: number = 0;
  if (d > 0) {
    if (max === rn) {
      h = 60 * (((gn - bn) / d) % 6);
    } else if (max === gn) {
      h = 60 * ((bn - rn) / d + 2);
    } else {
      h = 60 * ((rn - gn) / d + 4);
    }
  }
  if (h < 0) {
    h += 360;
  }
  const s: number = max === 0 ? 0 : d / max;
  return [Math.round(h), Math.round(s * 100), Math.round(max * 100)];
}

@Component
export struct ColorWheelPicker {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 当前颜色(#RRGGBB)。外部变化(如点击预设色块)时重新同步 HSV。 */
  @Prop @Watch('onColorPropChange') color: string = '#FF0000';
  /** 选中颜色变化回调(拖动/点击色盘时触发)。 */
  onChange: (color: string) => void = (color: string): void => {};

  /** 当前色相 0-360 */
  private hue: number = 0;
  /** 当前饱和度 0-100 */
  private sat: number = 100;
  /** 当前明度 0-100 */
  private val: number = 100;
  /** 最近一次对外发出的 Hex(用于避免自身回环重同步) */
  private lastEmittedHex: string = '';

  private svCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private hueCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private svW: number = 0;
  private svH: number = 0;
  private hueW: number = 0;
  private hueH: number = 0;

  aboutToAppear(): void {
    this.syncFromColor();
  }

  private onColorPropChange(): void {
    if (this.color.toUpperCase() === this.lastEmittedHex) {
      return;
    }
    this.syncFromColor();
  }

  /** 从 color prop 同步到 HSV 并重绘。 */
  private syncFromColor(): void {
    const rgb: [number, number, number] = hexToRgb(this.color);
    const hsv: [number, number, number] = rgbToHsv(rgb[0], rgb[1], rgb[2]);
    this.hue = hsv[0];
    this.sat = hsv[1];
    this.val = hsv[2];
    this.lastEmittedHex = rgbToHex(rgb[0], rgb[1], rgb[2]);
    this.redrawAll();
  }

  /** 依据当前 HSV 计算 Hex 并对外回调。 */
  private emit(): void {
    const hex: string = hsvToHex(this.hue, this.sat, this.val);
    this.lastEmittedHex = hex;
    this.onChange(hex);
  }

  private handleSvTouch(event: TouchEvent): void {
    if (event.touches.length === 0 || this.svW <= 0 || this.svH <= 0) {
      return;
    }
    this.sat = clamp01(event.touches[0].x / this.svW) * 100;
    this.val = (1 - clamp01(event.touches[0].y / this.svH)) * 100;
    this.redrawSv();
    this.emit();
  }

  private handleHueTouch(event: TouchEvent): void {
    if (event.touches.length === 0 || this.hueW <= 0) {
      return;
    }
    this.hue = clamp01(event.touches[0].x / this.hueW) * 360;
    this.redrawAll();
    this.emit();
  }

  private redrawAll(): void {
    this.redrawSv();
    this.redrawHue();
  }

  /** 绘制饱和度/明度二维区域 + 选中指示圆点。 */
  private redrawSv(): void {
    if (this.svW <= 0 || this.svH <= 0) {
      return;
    }
    const w: number = this.svW;
    const h: number = this.svH;
    const ctx: CanvasRenderingContext2D = this.svCtx;
    // 基底:纯色相(满饱和、满明度)
    const baseHex: string = hsvToHex(this.hue, 100, 100);
    ctx.fillStyle = baseHex;
    ctx.fillRect(0, 0, w, h);
    // 白色渐变(左→右):左端饱和度为 0(白),右端为纯色相
    const whiteGrad: CanvasGradient = ctx.createLinearGradient(0, 0, w, 0);
    whiteGrad.addColorStop(0, '#FFFFFF');
    whiteGrad.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = whiteGrad;
    ctx.fillRect(0, 0, w, h);
    // 黑色渐变(下→上):下端明度为 0(黑),上端为纯色相
    const blackGrad: CanvasGradient = ctx.createLinearGradient(0, h, 0, 0);
    blackGrad.addColorStop(0, '#000000');
    blackGrad.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = blackGrad;
    ctx.fillRect(0, 0, w, h);
    // 选中指示圆点
    this.drawThumb(ctx, (this.sat / 100) * w, (1 - this.val / 100) * h);
  }

  /** 绘制色相条 + 选中指示圆点。 */
  private redrawHue(): void {
    if (this.hueW <= 0 || this.hueH <= 0) {
      return;
    }
    const w: number = this.hueW;
    const h: number = this.hueH;
    const ctx: CanvasRenderingContext2D = this.hueCtx;
    const grad: CanvasGradient = ctx.createLinearGradient(0, 0, w, 0);
    grad.addColorStop(0, '#FF0000');
    grad.addColorStop(1 / 6, '#FFFF00');
    grad.addColorStop(2 / 6, '#00FF00');
    grad.addColorStop(3 / 6, '#00FFFF');
    grad.addColorStop(4 / 6, '#0000FF');
    grad.addColorStop(5 / 6, '#FF00FF');
    grad.addColorStop(1, '#FF0000');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, w, h);
    this.drawThumb(ctx, (this.hue / 360) * w, h / 2);
  }

  /** 绘制选中指示圆点(填充当前色 + 白边 + 淡黑描边)。 */
  private drawThumb(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    const current: string = hsvToHex(this.hue, this.sat, this.val);
    ctx.beginPath();
    ctx.arc(x, y, 7, 0, Math.PI * 2);
    ctx.fillStyle = current;
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x, y, 7, 0, Math.PI * 2);
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(x, y, 8.5, 0, Math.PI * 2);
    ctx.strokeStyle = 'rgba(0,0,0,0.35)';
    ctx.lineWidth = 1;
    ctx.stroke();
  }

  /** 将 Area 的尺寸(Length)转为数字(vp)。 */
  private lengthToNumber(length: Length): number {
    if (typeof length === 'number') {
      return length;
    }
    if (typeof length === 'string') {
      const numStr: string = length.replace(/vp$|px$/, '');
      const num: number = parseFloat(numStr);
      return isNaN(num) ? 0 : num;
    }
    return 0;
  }

  build() {
    Column() {
      // 饱和度/明度二维区域
      Canvas(this.svCtx)
        .width('100%')
        .height(200)
        .borderRadius(10)
        .onReady(() => {
          this.redrawSv();
        })
        .onAreaChange((_old: Area, newValue: Area) => {
          this.svW = this.lengthToNumber(newValue.width);
          this.svH = this.lengthToNumber(newValue.height);
          this.redrawSv();
        })
        .onTouch((event: TouchEvent) => {
          this.handleSvTouch(event);
        })

      // 色相条
      Canvas(this.hueCtx)
        .width('100%')
        .height(26)
        .borderRadius(13)
        .margin({ top: 12 })
        .onReady(() => {
          this.redrawHue();
        })
        .onAreaChange((_old: Area, newValue: Area) => {
          this.hueW = this.lengthToNumber(newValue.width);
          this.hueH = this.lengthToNumber(newValue.height);
          this.redrawHue();
        })
        .onTouch((event: TouchEvent) => {
          this.handleHueTouch(event);
        })

      // 当前颜色预览 + Hex 只读展示
      Row() {
        Stack()
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor(this.color)
          .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
        Text(this.color.toUpperCase())
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 10 })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 12 })
    }
    .width('100%')
  }
}
