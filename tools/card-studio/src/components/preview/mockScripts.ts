/**
 * 预览 mock 脚本构造:
 * - buildArkMockScript: App 端 arktavern Bridge mock(行为对齐 CardFrontendWeb.ets)
 * - buildStMockScript: 酒馆助手 TavernHelper API mock + 头像 CSS + jQuery
 * 注入方式:插到 <head> 后(无 head 则prepend),保证先于页面脚本执行。
 */
import jquerySource from 'jquery/dist/jquery.min.js?raw'
import type { StatusField } from '@/shared/card'

export interface ArkMockOptions {
  schema: StatusField[]
  character: { name: string; description?: string; personality?: string; scenario?: string; systemPrompt?: string }
}

export function injectScript(html: string, script: string): string {
  const tag = `<script>${script}</script>`
  const headIdx = html.search(/<head[^>]*>/i)
  if (headIdx >= 0) {
    const headEnd = html.indexOf('>', headIdx) + 1
    return html.slice(0, headEnd) + tag + html.slice(headEnd)
  }
  return tag + html
}

/** App 端 Bridge mock:状态数据保存在 iframe 内,Vue 侧经 window.__arkMock 控制 */
export function buildArkMockScript(options: ArkMockOptions): string {
  const schemaJson = JSON.stringify(options.schema ?? [])
  const characterJson = JSON.stringify(options.character ?? { name: '' })
  return `
(function () {
  var schema = ${schemaJson};
  var character = ${characterJson};
  var state = [];
  for (var i = 0; i < schema.length; i++) {
    state.push({ name: schema[i].name, value: '', fromUser: false, locked: !!schema[i].locked });
  }
  var lastAssistant = '';
  var generating = false;

  function dispatch(kind, data) {
    try {
      if (window.arktavernPush && typeof window.arktavernPush.dispatch === 'function') {
        window.arktavernPush.dispatch(JSON.stringify({ kind: kind, data: data }));
      }
    } catch (e) { /* 页面自身错误不影响 mock */ }
  }
  function findField(name) {
    for (var i = 0; i < schema.length; i++) if (schema[i].name === name) return schema[i];
    return null;
  }

  window.arktavern = {
    getVersion: function () { return '1'; },
    getState: function () { return JSON.stringify(state); },
    getStatusSchema: function () { return JSON.stringify(schema); },
    setState: function (name, value) {
      name = String(name == null ? '' : name);
      value = value == null ? '' : String(value);
      if (!name) return 'invalid';
      var idx = -1;
      for (var i = 0; i < state.length; i++) if (state[i].name === name) { idx = i; break; }
      var field = findField(name);
      if (value === '') {
        if (idx >= 0 && field && field.locked) return 'locked';
        if (idx >= 0) { state.splice(idx, 1); dispatch('status_update', state); }
        return 'ok';
      }
      if (idx >= 0) {
        if (field && field.locked) return 'locked';
        state[idx].value = value;
      } else {
        state.push({ name: name, value: value, fromUser: true, locked: false });
      }
      dispatch('status_update', state);
      return 'ok';
    },
    getCharacter: function () { return JSON.stringify(character); },
    send: function (text) {
      text = String(text == null ? '' : text);
      if (!text.trim()) return 'empty';
      if (window.__arkHost && window.__arkHost.onSend) window.__arkHost.onSend(text);
      return 'ok';
    },
    close: function () {
      if (window.__arkHost && window.__arkHost.onClose) window.__arkHost.onClose();
      return 'ok';
    }
  };

  window.__arkMock = {
    pushSnapshot: function () {
      dispatch('schema_update', schema);
      dispatch('status_update', state);
      dispatch('message_update', { generating: generating, lastAssistant: lastAssistant });
    },
    /** 模拟一条助手回复:解析 <|status|> 状态块 → 更新已声明字段 → 推送事件 */
    simulateReply: function (text) {
      var display = String(text == null ? '' : text);
      var m = /<\\|status\\|>\\s*([\\s\\S]*?)(?:<\\|\\/status\\|>|$)/.exec(display);
      if (m) {
        display = (display.slice(0, m.index) + display.slice(m.index + m[0].length)).trim();
        try {
          var obj = JSON.parse(m[1]);
          for (var k in obj) {
            var field = findField(k);
            if (!field || field.locked) continue;
            var hit = -1;
            for (var i = 0; i < state.length; i++) if (state[i].name === k) { hit = i; break; }
            if (hit >= 0) state[hit].value = String(obj[k]);
            else state.push({ name: k, value: String(obj[k]), fromUser: false, locked: false });
          }
        } catch (e) { /* 状态块 JSON 非法时仅展示正文 */ }
      }
      lastAssistant = display;
      generating = false;
      dispatch('status_update', state);
      dispatch('message_update', { generating: generating, lastAssistant: lastAssistant });
    },
    setGenerating: function (g) {
      generating = !!g;
      dispatch('message_update', { generating: generating, lastAssistant: lastAssistant });
    },
    getState: function () { return state; }
  };
})();
`
}

export interface StMockOptions {
  charName: string
  firstMes: string
  userName?: string
  charAvatarUrl?: string
  userAvatarUrl?: string
}

/** 酒馆助手环境 mock:jQuery + 常用 API + 头像 CSS */
export function buildStMockScript(options: StMockOptions): string {
  const charAvatar = options.charAvatarUrl || ''
  const userAvatar = options.userAvatarUrl || ''
  return `
(function () {
  if (!window.jQuery && !window.$) {
    ${jquerySource}
    window.jQuery = window.$ = jQuery;
    if (window.jQuery) { jQuery(function () {}); }
  }

  var variables = {};
  var messages = [
    { name: ${JSON.stringify(options.userName ?? 'User')}, is_user: true, mes: '你好' },
    { name: ${JSON.stringify(options.charName)}, is_user: false, mes: ${JSON.stringify((options.firstMes || '').slice(0, 2000))} }
  ];

  function resolve(target, value) {
    if (typeof target === 'string') { variables[target] = value; return; }
    for (var k in target) variables[k] = target[k];
  }

  window.getVariables = function () { return Promise.resolve(JSON.parse(JSON.stringify(variables))); };
  window.setVariables = function (v) { resolve(v, undefined); };
  window.insertOrReplaceVariables = function (pattern, value) { resolve(pattern, value); };
  window.getChatMessages = function () { return Promise.resolve(messages.slice()); };
  window.setChatMessages = function (msgs) {
    if (msgs && msgs.mes !== undefined) { if (messages[0]) messages[0].mes = msgs.mes; }
  };
  window.substitudeMacros = window.substituteMacros = function (t) { return String(t); };
  window.getCharAvatarUrl = function () { return ${JSON.stringify(charAvatar)}; };
  window.getUserAvatarUrl = function () { return ${JSON.stringify(userAvatar)}; };
  window.eventOn = function () {};
  window.eventOnce = function () {};
  window.eventEmit = function () {};
  window.triggerSlash = function (cmd) { console.log('[mock] triggerSlash:', String(cmd).slice(0, 200)); };
  window.generate = window.generateRaw = function (prompt) {
    return Promise.resolve('(ST 预览模拟回复,不连接模型)');
  };

  var style = document.createElement('style');
  style.textContent = [
    ${JSON.stringify(
      `.char-avatar,.char_avatar,.user-avatar,.user_avatar{background-size:cover;background-position:center;background-repeat:no-repeat;}`
    )},
    ${charAvatar ? `.char-avatar,.char_avatar{background-image:url(${charAvatar});}` : ''},
    ${userAvatar ? `.user-avatar,.user_avatar{background-image:url(${userAvatar});}` : ''}
  ].join('\\n');
  document.addEventListener('DOMContentLoaded', function () { document.head.appendChild(style); });
})();
`
}
