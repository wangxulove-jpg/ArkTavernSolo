/**
 * ArkTavern ST 兼容层(SillyTavern 酒馆助手 API Shim)
 *
 * 目的:让从 SillyTavern"原文导入"的前端页面(依赖 TavernHelper/jQuery/酒馆事件)
 *   在 ArkTavern 的 ArkWeb 前端容器里直接运行,数据接自 window.arktavern Bridge(契约 v3)。
 *
 * 注入位置:jQuery 之后、卡片 HTML 之前(见 bridge/StCompatShim.ets 与 CardFrontendWeb.ets)。
 * 事件节奏(2026-10 流式降频):
 *   - 流式生成中(generating=true)只轻量更新 lastAssistant/messageCount,不做 refresh() 全量拉取;
 *     逐字增量 emit STREAM_TOKEN_RECEIVED;getChatMessages() 在流式期间返回开始生成时的缓存快照;
 *   - 生成开始/结束帧与非流式变更帧做全量对齐;生成结束事件(GENERATION_ENDED/MESSAGE_RECEIVED/
 *     CHARACTER_MESSAGE_RENDERED)payload 带 message_id(过滤后索引近似值,超 200 条楼层有漂移)。
 * 已知边界(制卡工具会在导入时把这些接缝标出来让 AI 修补):
 *   - getWorldbook/getLorebookEntries 返回空(App 不提供世界书数据,需要时请改为内嵌数据)
 *   - replaceLastMessage/setChatMessages 为只读空实现(App 楼层不可从页面改写)
 *   - generate() 不支持(请改走 window.arktavern.send)
 *   - triggerSlash 仅映射 /send;其余命令忽略并告警
 *   - $1/$2 等正则捕获组属于显示期正则机制,原文导入时需改为 message_update/getMessages 渲染
 */
(function () {
  if (window.__stShimInstalled) { return; }
  window.__stShimInstalled = true;

  // ===== storage 兜底:loadData 源下 localStorage 可能抛 SecurityError =====
  function memoryStorage() {
    var map = {};
    return {
      getItem: function (k) { k = String(k); return Object.prototype.hasOwnProperty.call(map, k) ? map[k] : null; },
      setItem: function (k, v) { map[String(k)] = String(v); },
      removeItem: function (k) { delete map[String(k)]; },
      clear: function () { map = {}; },
      key: function (i) { var ks = Object.keys(map); return i >= 0 && i < ks.length ? ks[i] : null; },
      get length() { return Object.keys(map).length; }
    };
  }
  (function installStorage() {
    var names = ['localStorage', 'sessionStorage'];
    for (var n = 0; n < names.length; n++) {
      var usable = true;
      try { var s = window[names[n]]; if (s) { s.getItem('__st_shim_probe__'); } } catch (e) { usable = false; }
      if (usable) { continue; }
      try { Object.defineProperty(window, names[n], { value: memoryStorage(), configurable: true }); } catch (e2) { /* 忽略 */ }
    }
  })();

  function log() { try { console.log.apply(console, ['[st-shim]'].concat(Array.prototype.slice.call(arguments))); } catch (e) {} }
  function warn() { try { console.warn.apply(console, ['[st-shim]'].concat(Array.prototype.slice.call(arguments))); } catch (e) {} }

  // ===== 事件系统(页面 eventOn 注册,App 推送事件翻译后触发) =====
  var handlers = {};
  function eventOn(name, fn) {
    var key = String(name);
    if (typeof fn === 'function') { (handlers[key] = handlers[key] || []).push(fn); }
    return { stop: function () { eventRemoveListener(key, fn); } };
  }
  function eventRemoveListener(name, fn) {
    var list = handlers[String(name)];
    if (!list) { return; }
    if (!fn) { delete handlers[String(name)]; return; }
    var idx = list.indexOf(fn);
    if (idx >= 0) { list.splice(idx, 1); }
  }
  function emit(name, payload) {
    var list = (handlers[String(name)] || []).slice();
    for (var i = 0; i < list.length; i++) {
      try { list[i](payload); } catch (e) { warn('事件处理器出错:', e && e.message ? e.message : e); }
    }
    return [];
  }

  // ===== ST 事件常量(与 SillyTavern 酒馆助手一致) =====
  var TAVERN_EVENTS = {
    APP_READY: 'app_ready',
    EXTRAS_CONNECTED: 'extras_connected',
    MESSAGE_SWIPED: 'message_swiped',
    MESSAGE_SENT: 'message_sent',
    MESSAGE_RECEIVED: 'message_received',
    MESSAGE_EDITED: 'message_edited',
    MESSAGE_DELETED: 'message_deleted',
    MESSAGE_UPDATED: 'message_updated',
    MESSAGE_FILE_EMBEDDED: 'message_file_embedded',
    MESSAGE_PINNED: 'message_pinned',
    MESSAGE_UNPINNED: 'message_unpinned',
    IMPERSONATE_READY: 'impersonate_ready',
    CHAT_CHANGED: 'chat_id_changed',
    CHAT_CREATED: 'chat_created',
    CHAT_DELETED: 'chat_deleted',
    GENERATION_AFTER_COMMANDS: 'GENERATION_AFTER_COMMANDS',
    GENERATION_STARTED: 'generation_started',
    GENERATION_STOPPED: 'generation_stopped',
    GENERATION_ENDED: 'generation_ended',
    SETTINGS_LOADED: 'settings_loaded',
    SETTINGS_UPDATED: 'settings_updated',
    WORLDINFO_SETTINGS_UPDATED: 'worldinfo_settings_updated',
    WORLDINFO_UPDATED: 'worldinfo_updated',
    WORLD_INFO_ACTIVATED: 'world_info_activated',
    CHARACTER_EDITOR_OPENED: 'character_editor_opened',
    CHARACTER_EDITED: 'character_edited',
    CHARACTER_PAGE_LOADED: 'character_page_loaded',
    CHARACTER_MESSAGE_RENDERED: 'character_message_rendered',
    USER_MESSAGE_RENDERED: 'user_message_rendered',
    STREAM_TOKEN_RECEIVED: 'stream_token_received',
    GROUP_UPDATED: 'group_updated',
    MOVABLE_PANELS_RESET: 'movable_panels_reset',
    EXTENSIONS_FIRST_LOAD: 'extensions_first_load',
    EXTENSION_SETTINGS_LOADED: 'extension_settings_loaded'
  };
  var IFRAME_EVENTS = {
    MESSAGE_IFRAME_RENDER_STARTED: 'message_iframe_render_started',
    MESSAGE_IFRAME_RENDER_ENDED: 'message_iframe_render_ended',
    GENERATION_STARTED: TAVERN_EVENTS.GENERATION_STARTED,
    GENERATION_ENDED: TAVERN_EVENTS.GENERATION_ENDED
  };

  // ===== 数据缓存(接 Bridge,推送事件时刷新) =====
  var ark = null;
  var userName = 'User';
  var charName = '';
  var charInfo = {};
  var messagesCache = [];   // ST 楼层形态:{message_id,name,role,is_user,mes,is_hidden,swipe_id,swipes}
  var lastAssistant = '';
  var generating = false;
  var messageCount = 0;
  var varsCache = {};       // MVU 形态变量对象(由状态字段映射)
  var schemaCache = [];

  function thenable(value) {
    if (value && typeof value === 'object') {
      try {
        Object.defineProperty(value, 'then', {
          value: function (onOk) {
            if (typeof onOk === 'function') { onOk(Array.isArray(value) ? value.slice() : Object.assign({}, value)); }
            return value;
          },
          enumerable: false
        });
      } catch (e) { /* 不可扩展对象忽略 */ }
    }
    return value;
  }

  function refresh() {
    if (!ark) { return; }
    try {
      var arr = JSON.parse(ark.getMessages(200) || '[]');
      var out = [];
      for (var i = 0; i < arr.length; i++) {
        var m = arr[i] || {};
        var mes = String(m.content == null ? '' : m.content);
        var isUser = m.role === 'user';
        out.push({
          message_id: i, name: isUser ? userName : charName, role: isUser ? 'user' : 'assistant',
          is_user: isUser, mes: mes, is_hidden: false, swipe_id: 0, swipes: [mes]
        });
      }
      messagesCache = out;
      messageCount = out.length;
      for (var j = out.length - 1; j >= 0; j--) {
        if (!out[j].is_user) { lastAssistant = out[j].mes; break; }
      }
    } catch (e) { /* Bridge 未就绪时静默 */ }
    try {
      var st = JSON.parse(ark.getState() || '[]');
      var vo = {};
      for (var k = 0; k < st.length; k++) {
        if (st[k] && st[k].name !== undefined) { vo[String(st[k].name)] = st[k].value; }
      }
      varsCache = vo;
    } catch (e) { /* 同上 */ }
    try { schemaCache = JSON.parse(ark.getStatusSchema() || '[]'); } catch (e) { /* 同上 */ }
  }

  function initBridge() {
    ark = window.arktavern || null;
    if (!ark || typeof ark.getMessages !== 'function') { ark = null; return false; }
    try {
      charInfo = JSON.parse(ark.getCharacter() || '{}');
      charName = charInfo.name || '';
      userName = charInfo.userName || charInfo.user_name || 'User';
    } catch (e) { charInfo = {}; }
    refresh();
    // App → 页面推送通道:页面自己定义了 arktavernPush 时以页面为准(原生卡),ST 导入卡由 shim 提供
    if (!window.arktavernPush) {
      window.arktavernPush = {
        dispatch: function (json) {
          var ev = null;
          try { ev = typeof json === 'string' ? JSON.parse(json) : json; } catch (e) { return; }
          if (!ev || !ev.kind) { return; }
          if (ev.kind === 'message_update') {
            // 流式降频:generating=true 期间只做轻量字段更新(事件 data 已带 lastAssistant/messageCount),
            // 跳过 refresh() 全量拉取(每次 getMessages(200) 的同步开销会在流式期间淹没页面 JS,
            // 表现为前端卡顿/滞后);全量对齐推迟到生成结束帧与非流式变更帧。
            // 行为变化:流式期间 getChatMessages() 返回开始生成时的缓存快照(结束帧恢复全量对齐)。
            var d = ev.data || {};
            var was = generating;
            var prevLast = lastAssistant;
            generating = !!d.generating;
            if (typeof d.lastAssistant === 'string') { lastAssistant = d.lastAssistant; }
            if (typeof d.messageCount === 'number') { messageCount = d.messageCount; }
            if (generating) {
              // 逐字流式事件:diff 增量喂给 STREAM_TOKEN_RECEIVED(纯前缀追加时)
              if (lastAssistant.length > prevLast.length && lastAssistant.indexOf(prevLast) === 0) {
                emit(TAVERN_EVENTS.STREAM_TOKEN_RECEIVED, { text: lastAssistant.slice(prevLast.length) });
              }
            } else {
              refresh();
            }
            var mid = Math.max(0, messageCount - 1);
            if (generating && !was) {
              refresh(); // 生成开始(通常伴随新楼层):一次全量对齐
              emit(TAVERN_EVENTS.GENERATION_STARTED, {});
            }
            if (!generating && was) {
              // 生成结束:酒馆助手事件带 message_id(此前为空对象,依赖 payload 的页面拿不到数据)
              emit(TAVERN_EVENTS.GENERATION_ENDED, { message_id: mid });
              emit(TAVERN_EVENTS.MESSAGE_RECEIVED, { message_id: mid });
              emit(TAVERN_EVENTS.CHARACTER_MESSAGE_RENDERED, { message_id: mid });
            }
            emit(TAVERN_EVENTS.MESSAGE_UPDATED, {});
          } else if (ev.kind === 'status_update') {
            refresh();
            emit(TAVERN_EVENTS.WORLDINFO_UPDATED, {});
          } else if (ev.kind === 'schema_update') {
            refresh();
          }
        }
      };
    }
    return true;
  }

  if (!initBridge()) {
    // javaScriptProxy 晚于页面脚本就绪的兜底:轮询 3 秒
    var tries = 0;
    var bootTimer = setInterval(function () {
      tries += 1;
      if (initBridge()) {
        clearInterval(bootTimer);
        emit(TAVERN_EVENTS.APP_READY, {});
      } else if (tries > 30) {
        clearInterval(bootTimer);
        warn('window.arktavern 不可用,ST 兼容层未接入数据(原生卡无影响)');
      }
    }, 100);
  }

  // ===== 楼层范围解析:数字 / 数组 / '0-{{lastMessageId}}' 字符串 =====
  function pickMessages(range) {
    if (range === undefined || range === null || range === '') { return messagesCache.slice(); }
    var wanted = [];
    if (typeof range === 'number') { wanted = [range]; }
    else if (Array.isArray(range)) { wanted = range.slice(); }
    else {
      var lastId = messagesCache.length ? messagesCache[messagesCache.length - 1].message_id : 0;
      var text = String(range)
        .replace(/\{\{\s*lastMessageId\s*\}\}/gi, String(lastId))
        .replace(/\{\{\s*currentMessageId\s*\}\}/gi, String(Math.max(0, messageCount - 1)))
        .replace(/\{\{\s*firstMessageId\s*\}\}/gi, '0');
      var m;
      var rangeRe = /(\d+)\s*-\s*(\d+)|(\d+)/g;
      while ((m = rangeRe.exec(text)) !== null) {
        if (m[1] !== undefined) {
          var from = Number(m[1]);
          var to = Number(m[2]);
          for (var i = from; i <= to && i - from < 200; i++) { wanted.push(i); }
        } else { wanted.push(Number(m[3])); }
      }
    }
    if (!wanted.length) { return messagesCache.slice(); }
    return messagesCache.filter(function (msg) { return wanted.indexOf(msg.message_id) >= 0; });
  }

  function varsToObj() { return JSON.parse(JSON.stringify(varsCache)); }
  function applyVars(target, value) {
    if (!ark) { return false; }
    if (typeof target === 'string') {
      ark.setState(String(target), String(value == null ? '' : value));
    } else if (target && typeof target === 'object') {
      for (var k in target) {
        if (Object.prototype.hasOwnProperty.call(target, k)) {
          ark.setState(String(k), String(target[k] == null ? '' : target[k]));
        }
      }
    }
    refresh();
    return true;
  }

  function substituteMacrosImpl(t) {
    return String(t)
      .replace(/\{\{\s*user\s*\}\}/g, userName)
      .replace(/\{\{\s*char\s*\}\}/g, charName);
  }

  // ===== API 表(同步返回 + thenable 兼容 await) =====
  var api = {};
  // ---- 变量(映射 App 角色状态字段) ----
  api.getVariables = function () { return thenable(varsToObj()); };
  api.getVariable = function (name) { return varsCache[String(name)]; };
  api.setVariables = function (v) { if (v && typeof v === 'object' && !Array.isArray(v)) { applyVars(v, undefined); } return true; };
  api.replaceVariables = function (v) { return api.setVariables(v); };
  api.insertOrAssignVariables = function (v) { if (v && typeof v === 'object') { applyVars(v, undefined); } return thenable(varsToObj()); };
  api.insertVariables = api.insertOrAssignVariables;
  api.insertOrReplaceVariables = function (pattern, value) { applyVars(pattern, value); return true; };
  api.deleteVariable = function (name) { if (ark) { ark.setState(String(name), ''); } refresh(); return true; };
  api.updateVariablesWith = function (updater) {
    if (typeof updater === 'function') {
      var next = updater(varsToObj());
      if (next && typeof next === 'object') { applyVars(next, undefined); }
    }
    return thenable(varsToObj());
  };
  // ---- 楼层消息 ----
  api.getChatMessages = function (range, options) {
    var list = pickMessages(range);
    if (options && options.role) { list = list.filter(function (m) { return m.role === options.role; }); }
    return thenable(JSON.parse(JSON.stringify(list)));
  };
  api.setChatMessages = function () { warn('setChatMessages:App 楼层只读,已忽略'); return Promise.resolve(true); };
  api.createChatMessages = function () { warn('createChatMessages:不支持,已忽略'); return Promise.resolve([]); };
  api.deleteChatMessages = function () { warn('deleteChatMessages:不支持,已忽略'); return Promise.resolve(true); };
  api.rotateChatMessages = function () { return Promise.resolve(true); };
  api.getCurrentMessageId = function () { return Math.max(0, messageCount - 1); };
  api.getLastMessageId = function () { return Math.max(0, messageCount - 1); };
  api.isDuringSTGenerating = function () { return generating; };
  api.getLastMessage = function () { return thenable(lastAssistant); };
  api.formatAsDisplayedMessage = function (text) { return thenable(String(text)); };
  api.retrieveDisplayedMessage = function () { return thenable(lastAssistant); };
  api.replaceLastMessage = function (text) { warn('replaceLastMessage:App 楼层只读,已忽略'); return Promise.resolve(true); };
  api.substitudeMacros = substituteMacrosImpl;
  api.substituteMacros = substituteMacrosImpl;
  // ---- 角色 ----
  api.getCharacterCardFields = function () {
    return thenable({
      name: charName,
      description: charInfo.description || '',
      personality: charInfo.personality || '',
      scenario: charInfo.scenario || '',
      system_prompt: charInfo.systemPrompt || ''
    });
  };
  api.getCurrentCharName = function () { return charName; };
  api.getCharAvatarUrl = function () { return ''; };
  api.getCharAvatarPath = function () { return ''; };
  api.getUserAvatarUrl = function () { return ''; };
  // ---- 世界书(App 不提供,导入工具会标注此接缝) ----
  api.getWorldbookNames = function () { return thenable([]); };
  api.getWorldbook = function () { warn('getWorldbook:App 未提供世界书数据(需要时请改为内嵌数据)'); return thenable([]); };
  api.getLorebookEntries = api.getWorldbook;
  api.getLorebookSettings = function () { return thenable({}); };
  api.getWorldbookSettings = api.getLorebookSettings;
  api.getCharLorebooks = function () { return thenable({ primary: null, additional: [] }); };
  api.getCurrentCharPrimaryLorebook = function () { return thenable(null); };
  api.createWorldbook = function () { return thenable(true); };
  api.replaceWorldbook = function () { return thenable(true); };
  api.setWorldbook = function () { return thenable(true); };
  api.deleteWorldbook = function () { return thenable(true); };
  api.createLorebookEntries = function () { return thenable(true); };
  api.replaceLorebookEntries = function () { return thenable(true); };
  api.setLorebookEntries = function () { return thenable(true); };
  api.deleteLorebookEntries = function () { return thenable(true); };
  api.setLorebookSettings = function () { return true; };
  api.setWorldbookSettings = function () { return true; };
  // ---- 事件 ----
  api.eventOn = eventOn;
  api.eventOnce = function (name, fn) {
    var handle = eventOn(name, function (payload) { try { if (fn) { fn(payload); } } finally { handle.stop(); } });
    return handle;
  };
  api.eventEmit = function (name, payload) { return Promise.resolve(emit(name, payload)); };
  api.eventRemoveListener = eventRemoveListener;
  api.eventClearEvent = function (name) { delete handlers[String(name)]; };
  api.eventClearAll = function () { handlers = {}; };
  api.tavern_events = TAVERN_EVENTS;
  api.iframe_events = IFRAME_EVENTS;
  // ---- 生成 ----
  api.generate = function () { warn('generate():不支持,如需回复请用 window.arktavern.send(text)'); return Promise.resolve(''); };
  api.generateRaw = api.generate;
  api.stopGenerationById = function () { return true; };
  api.stopAllGeneration = function () { return true; };
  api.getModelList = function () { return thenable([]); };
  // ---- slash / 脚本 / 杂项 ----
  api.triggerSlash = function (cmd) {
    var s = String(cmd == null ? '' : cmd).trim();
    var m = /^\/(?:send|sendas|sendasuser)\s+([\s\S]+)$/i.exec(s);
    if (m && ark) { ark.send(m[1]); return ''; }
    warn('triggerSlash 不支持(仅映射 /send),已忽略:', s.slice(0, 80));
    return '';
  };
  api.triggerSlashWithResult = api.triggerSlash;
  api.getScriptId = function () { return 'arktavern-st-compat'; };
  api.getScriptName = function () { return 'ArkTavern ST 兼容层'; };
  api.getScriptInfo = function () { return thenable({ id: 'arktavern-st-compat', name: 'ArkTavern ST 兼容层' }); };
  api.getScriptButtons = function () { return thenable([]); };
  api.replaceScriptButtons = function () { return thenable(true); };
  api.getButtonEvent = function () { return ''; };
  api.setButtonEvent = function () { return true; };
  api.getPresetNames = function () { return thenable([]); };
  api.getPreset = function () { return thenable({}); };
  api.setPreset = function () { return thenable({}); };
  api.getTavernHelperVersion = function () { return 'ArkTavern ST 兼容层 v1'; };
  api.getVersion = api.getTavernHelperVersion;
  api.waitGlobalInitialized = function (name, timeout) {
    var key = String(name);
    var limit = typeof timeout === 'number' && timeout > 0 ? timeout : 5000;
    return new Promise(function (resolve) {
      if (typeof window[key] !== 'undefined') { resolve(); return; }
      var waited = 0;
      var timer = setInterval(function () {
        waited += 100;
        if (typeof window[key] !== 'undefined' || waited >= limit) { clearInterval(timer); resolve(); }
      }, 100);
    });
  };

  // ===== 全局注入(酒馆助手 iframe 里这些是全局;不覆盖页面已有) =====
  function toastrStub() {
    var t = { options: {} };
    var levels = ['info', 'success', 'warning', 'error'];
    for (var i = 0; i < levels.length; i++) {
      (function (lv) {
        t[lv] = function () {
          var parts = [];
          for (var j = 0; j < arguments.length; j++) { parts.push(String(arguments[j])); }
          log('toastr.' + lv + ':', parts.join(' ').slice(0, 200));
        };
      })(levels[i]);
    }
    t.clear = function () {};
    t.remove = function () {};
    return t;
  }
  var GLOBALS = { tavern_events: TAVERN_EVENTS, iframe_events: IFRAME_EVENTS, event_types: TAVERN_EVENTS, toastr: toastrStub() };
  var globalNames = [];
  for (var gk in api) { globalNames.push(gk); }
  for (var ek in GLOBALS) { if (globalNames.indexOf(ek) < 0) { globalNames.push(ek); } }
  for (var gi = 0; gi < globalNames.length; gi++) {
    var nm = globalNames[gi];
    var val = (nm in api) ? api[nm] : GLOBALS[nm];
    if (typeof window[nm] === 'undefined') { window[nm] = val; }
  }

  // ===== TavernHelper 代理:未实现 API 返回空壳,页面不中断 =====
  function makeStub(path) {
    var target = function () {};
    var stub = new Proxy(target, {
      get: function (t, key) {
        if (key in t) { return t[key]; }
        if (typeof key !== 'string') { return undefined; }
        return makeStub(path + '.' + key);
      },
      apply: function () { return makeStub(path + '()'); }
    });
    target.then = function (onOk) { if (typeof onOk === 'function') { try { onOk(undefined); } catch (e) {} } return stub; };
    target.catch = function () { return stub; };
    target.finally = function () { return stub; };
    target.includes = function () { return false; };
    target.indexOf = function () { return -1; };
    target.slice = function () { return []; };
    target.map = function () { return []; };
    target.filter = function () { return []; };
    target.forEach = function () {};
    target.push = function () { return 0; };
    target.join = function () { return ''; };
    target.toString = function () { return ''; };
    target.valueOf = function () { return ''; };
    target.length = 0;
    stub[Symbol.iterator] = function () { return { next: function () { return { done: true }; } }; };
    return stub;
  }

  var warned = {};
  window.TavernHelper = new Proxy(api, {
    get: function (t, key) {
      if (key in t) { return t[key]; }
      if (typeof key !== 'string') { return undefined; }
      if (!warned[key]) {
        warned[key] = true;
        warn('未实现的酒馆助手 API:' + key + '(返回空壳占位,页面不会中断)');
      }
      return makeStub('TavernHelper.' + key);
    }
  });

  // MVU 框架命名空间空壳:防止 MvuHelper.xxx 直接 ReferenceError;
  // 数据为空——变量体系应转成角色状态字段后改走 getVariables 族(导入工具会标注此接缝)
  if (typeof window.MvuHelper === 'undefined') {
    window.MvuHelper = makeStub('MvuHelper');
  }

  log('ST 兼容层已注入(jQuery ' + (window.jQuery ? jQuery.fn.jquery : '无') + ' · Bridge ' + (ark ? '已连接' : '等待中') + ')');
})();
