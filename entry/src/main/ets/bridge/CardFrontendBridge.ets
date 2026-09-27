/**
 * CardFrontendBridge 前端页面 JS Bridge(契约版本 v2)
 *
 * 通过 ArkWeb 的 javaScriptProxy 注入到角色卡前端页面,暴露 `window.arktavern.*` 方法:
 * - getVersion / getState / getStatusSchema / setState / getCharacter / getMessages / send / close
 *
 * App → 页面事件由 FrontendCardPage/ChatPage 面板通过 runJavaScript 调用 `window.arktavernPush.dispatch(json)`:
 * - message_update: 消息更新(含当前生成中状态、最后一条助手消息、消息总数)
 * - status_update:   角色状态更新
 *
 * 设计约束:
 * - 普通 class,不依赖 ArkUI,可由 FrontendCardPage 注入 pushFunc 与 logger
 * - 所有 JS 可调方法只返回同步字符串(避免 JS proxy 对异步返回值的不确定支持)
 * - 不持有 @State;通过宿主契约(FrontendCardHost,页面传入 ChatViewModel)的多订阅
 *   (subscribeMessages/subscribeStatus)接收更新
 * - 与 ChatPage 的原生回调(onMessagesUpdate 等)并存,不互相覆盖
 *
 * 版本历史:
 * - v1:getVersion/getState/getStatusSchema/setState/getCharacter/send/close
 * - v2:新增 getMessages(limit)(历史消息,供全屏前端页在页面内自绘对话)与
 *      message_update.messageCount(计数对齐用);frontend.chrome 支持 'none' 沉浸
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatStatusState } from '../models/ChatStatusState';
import { Character } from '../models/Character';

/** Bridge 提供给页面的契约版本号(v3: 新增 appendInteraction;v1/v2 能力全保留) */
const BRIDGE_VERSION: string = '3';

/** getMessages 默认返回条数(不传 limit 时) */
const DEFAULT_MESSAGE_LIMIT: number = 50;

/** getMessages 允许的最大返回条数 */
const MAX_MESSAGE_LIMIT: number = 200;

/**
 * 前端页面规格(arktavern-card-extensions v1)。
 * - 兼容旧写法:extensions.arktavern.frontend 为字符串 → mode='fullscreen'(全屏页)
 * - 新写法:对象 { html, mode?, title?, size?, chrome? }
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
  /** 全屏页外观:'auto'(默认,带 App 顶栏) | 'none'(沉浸,无 App 顶栏) */
  chrome: string;
}

function emptyFrontendSpec(): FrontendSpec {
  return {
    html: '', mode: 'fullscreen', title: '', sizeWidth: 0, sizeHeight: '', chrome: 'auto'
  };
}

/**
 * 从角色卡 extensions 解析 extensions.arktavern.frontend 前端页面规格。
 * - frontend 为字符串 → 兼容旧卡,等价 mode='fullscreen',html 即字符串
 * - frontend 为对象 → { html, mode?, title?, size?, chrome? }
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
      sizeHeight: '',
      chrome: 'auto'
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
    sizeHeight: sizeHeight,
    chrome: fo['chrome'] === 'none' ? 'none' : 'auto'
  };
}

/**
 * 从角色卡 extensions 提取前端页面 HTML(向后兼容入口,等价 extractFrontendSpec().html)。
 * 非对象 / 非字符串 / 缺失时返回空字符串。
 */
export function extractFrontendHtml(extensions: Record<string, Object>): string {
  return extractFrontendSpec(extensions).html;
}

/** getMessages 返回的单条消息(契约 v2) */
export interface FrontendMessageEntry {
  /** 'user' | 'assistant' */
  role: string;
  /** 正文(角色卡状态块已在入库时剥离) */
  content: string;
}

/** 归一化 getMessages 的 limit:非法/非正数取默认,超出上限截断 */
function normalizeMessageLimit(limit: number): number {
  const n: number = Number(limit);
  if (!Number.isFinite(n) || n <= 0) {
    return DEFAULT_MESSAGE_LIMIT;
  }
  return Math.min(Math.floor(n), MAX_MESSAGE_LIMIT);
}

/**
 * 构造 getMessages 返回的 JSON(最近 limit 条,按时间正序)。
 * 只保留 user/assistant 且正文非空的消息;纯函数,便于单测。
 */
export function buildMessagesJson(messages: ChatMessage[], limit: number): string {
  const n: number = normalizeMessageLimit(limit);
  const picked: FrontendMessageEntry[] = [];
  for (let i = messages.length - 1; i >= 0 && picked.length < n; i--) {
    const msg: ChatMessage = messages[i];
    let role: string = '';
    if (msg.role === ChatRole.User) {
      role = 'user';
    } else if (msg.role === ChatRole.Assistant) {
      role = 'assistant';
    }
    if (role.length === 0 || msg.content.length === 0) {
      continue;
    }
    picked.push({ role: role, content: msg.content });
  }
  picked.reverse();
  return JSON.stringify(picked);
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
  /** 当前会话消息总数(页面据此发现与本地不一致时重新 getMessages 对齐) */
  messageCount: number;
}

/**
 * 角色卡前端页面(全屏页 / 聊天页面板)所需的宿主契约。
 *
 * 目的:components 与 bridge 不直接依赖 viewmodels 层,只依赖本契约;
 * 页面把会话对象直接作为 host 传入(ChatViewModel 结构上满足本接口,无需适配器)。
 */
export interface FrontendCardHost {
  /** 当前角色卡(无角色时 null;无值时页面报"没有可用的前端界面") */
  currentCharacter: Character | null;
  /** 当前会话消息(按时间正序) */
  messages: ChatMessage[];
  /** 当前角色状态(entries 供 getState/setState/status_update 使用) */
  statusState: ChatStatusState;
  /** 是否正在生成(message_update 事件下发) */
  isGenerating: boolean;
  /** 是否忙(send 拒绝) */
  busy: boolean;
  /** 会话是否就绪(send 拒绝) */
  isSessionReady: boolean;
  /** 角色卡声明的状态 Schema JSON;无声明返回 '[]' */
  statusSchemaJson(): string;
  /** 订阅消息更新 */
  subscribeMessages(listener: (messages: ChatMessage[]) => void): void;
  /** 退订消息更新 */
  unsubscribeMessages(listener: (messages: ChatMessage[]) => void): void;
  /** 订阅状态更新 */
  subscribeStatus(listener: (state: ChatStatusState) => void): void;
  /** 退订状态更新 */
  unsubscribeStatus(listener: (state: ChatStatusState) => void): void;
  /** 以正常聊天链路发送一条消息(消息进入聊天气泡流) */
  sendExternalText(text: string): Promise<boolean>;
  /** 追加前端交互记录(不进聊天历史,随提示词段进入模型上下文) */
  appendFrontendInteraction(text: string): boolean;
  /** 新增状态字段 */
  addStatusField(name: string): void;
  /** 写入状态字段值 */
  setStatusFieldValue(name: string, value: string): void;
  /** 删除状态字段 */
  removeStatusField(name: string): void;
}

export class CardFrontendBridge {
  private readonly host: FrontendCardHost;
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
    host: FrontendCardHost,
    characterInfo: FrontendCardCharacterInfo,
    logger: (msg: string) => void
  ) {
    this.host = host;
    this.logger = logger;
    this.characterJson = JSON.stringify(characterInfo);
    this.messageListener = (messages: ChatMessage[]): void => {
      this.notifyMessageUpdate(messages);
    };
    this.statusListener = (state: ChatStatusState): void => {
      this.notifyStatusUpdate(state);
    };
  }

  /** 开始订阅宿主事件(页面加载完成前即可调用,事件在页面就绪后统一入队) */
  start(): void {
    this.host.subscribeMessages(this.messageListener);
    this.host.subscribeStatus(this.statusListener);
  }

  /** 停止订阅并清理引用(页面退出时调用) */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.host.unsubscribeMessages(this.messageListener);
    this.host.unsubscribeStatus(this.statusListener);
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
    return JSON.stringify(this.host.statusState.entries);
  }

  /** 返回角色卡声明的状态 Schema JSON:[{name,desc,type,locked}, ...];无声明返回 '[]' */
  getStatusSchema(): string {
    return this.host.statusSchemaJson();
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
    const entries = this.host.statusState.entries;
    let exists: boolean = false;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name === trimmedName) {
        exists = true;
        break;
      }
    }
    if (exists) {
      if (value.trim().length === 0) {
        this.host.removeStatusField(trimmedName);
      } else {
        this.host.setStatusFieldValue(trimmedName, value);
      }
    } else {
      if (value.trim().length > 0) {
        this.host.addStatusField(trimmedName);
        this.host.setStatusFieldValue(trimmedName, value);
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
   * 返回最近 N 条会话消息 JSON(契约 v2):
   * `[{"role":"user"|"assistant","content":"..."}]`,按时间正序。
   * 供全屏前端页在页面内自绘对话时拉取历史;流式增量仍走 message_update 事件。
   * @param limit 条数(默认 50,上限 200);非法值按默认处理
   */
  getMessages(limit: number): string {
    if (this.disposed) {
      return '[]';
    }
    return buildMessagesJson(this.host.messages, limit);
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
    if (this.host.busy || !this.host.isSessionReady) {
      this.logger('send blocked: busy=' + this.host.busy.toString()
        + ' ready=' + this.host.isSessionReady.toString());
      return 'busy';
    }
    void this.host.sendExternalText(trimmed);
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

  /**
   * 记录一条界面交互(契约 v3):**不触发模型请求、不写聊天历史、不进聊天气泡**,
   * 只攒进会话缓冲,下一轮正常发言时随「前端交互记录」提示词段进入模型上下文。
   * 适合轻交互(点选项、买东西、切界面);需要角色立刻回应时才用 send()(会发一次完整请求)。
   * 返回 'ok' / 'empty' / 'disposed'。
   */
  appendInteraction(text: string): string {
    if (this.disposed) {
      return 'disposed';
    }
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return 'empty';
    }
    const ok: boolean = this.host.appendFrontendInteraction(trimmed);
    if (!ok) {
      return 'empty';
    }
    this.logger('appendInteraction: ' + (trimmed.length > 48 ? trimmed.substring(0, 48) + '…' : trimmed));
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
      generating: this.host.isGenerating,
      lastAssistant: lastAssistant,
      messageCount: messages.length
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