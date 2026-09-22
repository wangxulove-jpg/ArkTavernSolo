/**
 * CardFrontendBridge 前端页面 JS Bridge(契约版本 v1)
 *
 * 通过 ArkWeb 的 javaScriptProxy 注入到角色卡前端页面,暴露 `window.arktavern.*` 方法:
 * - getVersion / getState / setState / getCharacter / send / close
 *
 * App → 页面事件由 FrontendCardPage 通过 runJavaScript 调用 `window.arktavernPush.dispatch(json)`:
 * - message_update: 消息更新(含当前生成中状态与最后一条助手消息)
 * - status_update:   角色状态更新
 *
 * 设计约束:
 * - 普通 class,不依赖 ArkUI,可由 FrontendCardPage 注入 pushFunc 与 logger
 * - 所有 JS 可调方法只返回同步字符串(避免 JS proxy 对异步返回值的不确定支持)
 * - 不持有 @State;通过 ChatViewModel 的多订阅(subscribeMessages/subscribeStatus)接收更新
 * - 与 ChatPage 的原生回调(onMessagesUpdate 等)并存,不互相覆盖
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatStatusState } from '../models/ChatStatusState';

/** Bridge 提供给页面的契约版本号 */
const BRIDGE_VERSION: string = '1';

/**
 * 前端页面规格(arktavern-card-extensions v1)。
 * - 兼容旧写法:extensions.arktavern.frontend 为字符串 → mode='fullscreen'(全屏页)
 * - 新写法:对象 { html, mode?, title?, size? }
 */
export interface FrontendSpec {
  /** 完整 HTML 字符串(含 <style>/<script>,全部内联) */
  html: string;
  /** 'fullscreen'(默认) | 'panel'(聊天页内嵌浮层面板) */
  mode: string;
  /** 面板/页标题(缺省用角色名) */
  title: string;
  /** panel 模式建议宽度(vp);0=未指定 */
  sizeWidth: number;
  /** panel 模式建议高度(vp 或百分比);'' = 未指定 */
  sizeHeight: string;
}

function emptyFrontendSpec(): FrontendSpec {
  return { html: '', mode: 'fullscreen', title: '', sizeWidth: 0, sizeHeight: '' };
}

/**
 * 从角色卡 extensions 解析 extensions.arktavern.frontend 前端页面规格。
 * - frontend 为字符串 → 兼容旧卡,等价 mode='fullscreen',html 即字符串
 * - frontend 为对象 → { html, mode?, title?, size? }
 * - 缺失/类型不合法 → 返回空规格(html 为 '')
 */
export function extractFrontendSpec(extensions: Record<string, Object>): FrontendSpec {
  const arktavern: Object | undefined = extensions['arktavern'];
  if (arktavern === undefined || !(arktavern instanceof Object)) {
    return emptyFrontendSpec();
  }
  const rec: Record<string, Object> = arktavern as Record<string, Object>;
  const frontend: Object | undefined = rec['frontend'];
  if (typeof frontend === 'string') {
    return {
      html: frontend as string,
      mode: 'fullscreen',
      title: '',
      sizeWidth: 0,
      sizeHeight: ''
    };
  }
  if (!(frontend instanceof Object)) {
    return emptyFrontendSpec();
  }
  const fo: Record<string, Object> = frontend as Record<string, Object>;
  const html: Object | undefined = fo['html'];
  if (typeof html !== 'string' || (html as string).length === 0) {
    return emptyFrontendSpec();
  }
  const mode: string =
    typeof fo['mode'] === 'string' ? (fo['mode'] as string) : 'fullscreen';
  const title: string =
    typeof fo['title'] === 'string' ? (fo['title'] as string) : '';
  let sizeWidth: number = 0;
  let sizeHeight: string = '';
  const size: Object | undefined = fo['size'];
  if (size instanceof Object) {
    const srec: Record<string, Object> = size as Record<string, Object>;
    if (typeof srec['width'] === 'number') {
      sizeWidth = srec['width'] as number;
    } else if (typeof srec['width'] === 'string') {
      sizeWidth = Number(srec['width'] as string);
    }
    if (typeof srec['height'] === 'string') {
      sizeHeight = srec['height'] as string;
    }
  }
  return {
    html: html as string,
    mode: mode === 'panel' ? 'panel' : 'fullscreen',
    title: title,
    sizeWidth: sizeWidth,
    sizeHeight: sizeHeight
  };
}

/**
 * 从角色卡 extensions 提取前端页面 HTML(向后兼容入口,等价 extractFrontendSpec().html)。
 * 非对象 / 非字符串 / 缺失时返回空字符串。
 */
export function extractFrontendHtml(extensions: Record<string, Object>): string {
  return extractFrontendSpec(extensions).html;
}

/** 角色卡前端页面可用的角色信息(构造时快照,避免动态绑定) */
export interface FrontendCardCharacterInfo {
  name: string;
  description: string;
  personality: string;
  scenario: string;
  systemPrompt: string;
}

/** App → 页面推送事件(data 为任意 JSON 序列化对象) */
interface PushEvent {
  kind: string;
  data: Object;
}

/** message_update 事件 data */
interface MessageUpdateData {
  generating: boolean;
  lastAssistant: string;
}

export class CardFrontendBridge {
  private readonly viewModel: ChatViewModel;
  private readonly characterJson: string;
  private readonly logger: (msg: string) => void;
  /** 由 FrontendCardPage 注入:向页面 JS 推送事件(字符串为 JSON 序列化后的消息) */
  pushFunc: ((json: string) => void) | null = null;
  /** 由 FrontendCardPage 注入:关闭页面(router.back) */
  closeHandler: (() => void) | null = null;
  private disposed: boolean = false;
  // ===== 订阅引用(保持同一引用以便 dispose 精确退订) =====
  private readonly messageListener: (messages: ChatMessage[]) => void;
  private readonly statusListener: (state: ChatStatusState) => void;

  constructor(
    viewModel: ChatViewModel,
    characterInfo: FrontendCardCharacterInfo,
    logger: (msg: string) => void
  ) {
    this.viewModel = viewModel;
    this.logger = logger;
    this.characterJson = JSON.stringify(characterInfo);
    this.messageListener = (messages: ChatMessage[]): void => {
      this.notifyMessageUpdate(messages);
    };
    this.statusListener = (state: ChatStatusState): void => {
      this.notifyStatusUpdate(state);
    };
  }

  /** 开始订阅 ChatViewModel 事件(页面加载完成前即可调用,事件在页面就绪后统一入队) */
  start(): void {
    this.viewModel.subscribeMessages(this.messageListener);
    this.viewModel.subscribeStatus(this.statusListener);
  }

  /** 停止订阅并清理引用(页面退出时调用) */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.viewModel.unsubscribeMessages(this.messageListener);
    this.viewModel.unsubscribeStatus(this.statusListener);
    this.pushFunc = null;
    this.closeHandler = null;
  }

  // ===== window.arktavern.*(javaScriptProxy methodList 声明的公共方法) =====

  /** 返回契约版本号(供页面/PC 工具自查兼容性) */
  getVersion(): string {
    return BRIDGE_VERSION;
  }

  /** 返回当前角色状态字段数组 JSON,如 [{name,value,fromUser,locked}, ...] */
  getState(): string {
    return JSON.stringify(this.viewModel.statusState.entries);
  }

  /** 返回角色卡声明的状态 Schema JSON:[{name,desc,type,locked}, ...];无声明返回 '[]' */
  getStatusSchema(): string {
    return this.viewModel.statusSchemaJson();
  }

  /**
   * 写角色状态字段:存在则更新(空值删除),不存在则新增(空值忽略)。
   * 写走后端统一 updateStatusState 链路,并广播 status_update 事件。
   */
  setState(name: string, value: string): string {
    const trimmedName: string = name.trim();
    if (this.disposed) {
      return 'disposed';
    }
    if (trimmedName.length === 0) {
      return 'invalid';
    }
    const entries = this.viewModel.statusState.entries;
    let exists: boolean = false;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name === trimmedName) {
        exists = true;
        break;
      }
    }
    if (exists) {
      if (value.trim().length === 0) {
        this.viewModel.removeStatusField(trimmedName);
      } else {
        this.viewModel.setStatusFieldValue(trimmedName, value);
      }
    } else {
      if (value.trim().length > 0) {
        this.viewModel.addStatusField(trimmedName);
        this.viewModel.setStatusFieldValue(trimmedName, value);
      }
    }
    this.logger('setState: ' + trimmedName + ' = ' + value);
    return 'ok';
  }

  /** 返回角色卡基础信息 JSON(名称/描述/性格/场景/系统提示) */
  getCharacter(): string {
    return this.characterJson;
  }

  /**
   * 发送一条消息到当前会话(与正常聊天同链路,消息会进入聊天气泡流)。
   * 返回 'ok' / 'busy' / 'empty' / 'disposed';发送结果通过 message_update 事件反馈。
   */
  send(text: string): string {
    if (this.disposed) {
      return 'disposed';
    }
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return 'empty';
    }
    if (this.viewModel.busy || !this.viewModel.isSessionReady) {
      this.logger('send blocked: busy=' + this.viewModel.busy.toString()
        + ' ready=' + this.viewModel.isSessionReady.toString());
      return 'busy';
    }
    void this.viewModel.sendExternalText(trimmed);
    this.logger('send ok: ' + (trimmed.length > 32 ? trimmed.substring(0, 32) + '…' : trimmed));
    return 'ok';
  }

  /** 关闭前端页面并返回聊天页 */
  close(): string {
    if (this.closeHandler !== null) {
      this.closeHandler();
    }
    return 'ok';
  }

  // ===== 内部 =====

  private notifyMessageUpdate(messages: ChatMessage[]): void {
    if (this.disposed || this.pushFunc === null) {
      return;
    }
    let lastAssistant: string = '';
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === ChatRole.Assistant) {
        lastAssistant = messages[i].content;
        break;
      }
    }
    const data: MessageUpdateData = {
      generating: this.viewModel.isGenerating,
      lastAssistant: lastAssistant
    };
    this.pushEvent('message_update', data);
  }

  private notifyStatusUpdate(state: ChatStatusState): void {
    if (this.disposed || this.pushFunc === null) {
      return;
    }
    this.pushEvent('status_update', state.entries);
  }

  private pushEvent(kind: string, data: Object): void {
    if (this.disposed || this.pushFunc === null) {
      return;
    }
    const event: PushEvent = { kind: kind, data: data };
    this.pushFunc(JSON.stringify(event));
  }
}