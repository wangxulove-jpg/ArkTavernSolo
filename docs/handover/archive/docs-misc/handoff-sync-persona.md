# ArkTavernSolo — Persona系统 & WebDAV同步 交接文档

> 最后更新: 2026-08-21 | 提交: `6a33993` | 数据库版本: v35

---

## 一、功能概览

| 功能 | 说明 |
|------|------|
| **Persona (人格预设)** | 可创建/编辑/删除独立人格预设，绑定到角色或聊天，控制 prompt 注入位置和深度 |
| **WebDAV 同步** | 基于坚果云 WebDAV 的双向增量同步，支持表数据、偏好设置、API密钥、图片 |
| **增量下载** | 本地缓存 manifest，仅下载 hash 变化的文件，节省流量 |
| **AES-256-GCM 加密** | API 密钥使用坚果云密码派生的密钥加密后传输和存储 |

---

## 二、架构总览

```
EntryAbility (onCreate)
  ├─ AppServices.initialize()
  └─ triggerAutoSync()
       └─ WebDavSyncService.autoSync()

SyncSettingsPage (UI)
  └─ SyncViewModel
       ├─ SyncConfigStore (Preferences 持久化)
       └─ WebDavSyncService
            ├─ WebDavClient (HTTP/WebDAV 协议)
            ├─ SyncDataExporter (导出)
            └─ SyncDataImporter (导入)

PersonaListPage / PersonaEditPage (UI)
  └─ PersonaViewModel
       └─ PersonaService
            ├─ PersonaRepository (DbHelper)
            └─ PersonaSelectionStore (默认人格选择)
```

---

## 三、WebDAV 同步详解

### 3.1 远程文件结构

```
/ArkTavernSolo/
  ├─ manifest.json          # 文件清单 (hash + size)
  ├─ prefs.json             # 偏好设置键值对
  ├─ keys.json              # 加密的 API 密钥
  ├─ tables/
  │   ├─ characters.json    # 每张表一个文件
  │   ├─ chats.json
  │   ├─ messages.json
  │   └─ ... (共38张表)
  └─ images/
      └─ avatars/
          └─ *.png          # 图片二进制文件
```

### 3.2 同步流程

| 操作 | 流程 |
|------|------|
| **上传** | 导出各表 → 计算 hash → 比对远程 manifest → 仅上传变化的文件 → 更新 manifest |
| **下载** | 下载远程 manifest → 比对本地缓存的 manifest → 仅下载变化的文件 → 导入 (latest-wins) |
| **双向** | 检查远程 manifest → 若同设备且时间一致则跳过 → 否则执行上传 |

### 3.3 增量下载机制

1. 每次上传/下载成功后，将远程 `manifest.json` 保存到本地 Preferences (`sync_last_manifest`)
2. 下次下载时，解析本地缓存的 manifest 与远程 manifest 比对
3. `fileChanged(key, remoteFiles, localManifest)` 比较 hash — 仅 hash 变化的文件才下载
4. 适用于：表数据、偏好设置、密钥文件、图片

### 3.4 冲突解决 (Latest-Wins)

导入每行数据时：
- 本地不存在该行 → `INSERT OR REPLACE`
- 远程 `updated_at` > 本地 `updated_at` → `INSERT OR REPLACE`
- 远程 `updated_at` <= 本地 → 跳过
- 无 `updated_at` 列 → `INSERT OR REPLACE`

**注意：远程删除不会同步到本地（只有新增/更新）**

### 3.5 导入时排除的 Preferences 键

以下键不从云端覆盖，防止同步设置被远端覆盖：

| 排除的键 | 原因 |
|----------|------|
| `sync_auto_enabled` | 本机自主决定是否自动同步 |
| `sync_wifi_only` | 本机网络环境可能不同 |

### 3.6 Toggle 设置持久化

`SyncSettingsPage` 中 Toggle 开关 (仅WiFi / 自动同步) 的 `onChange` 回调立即调用：
1. `syncToViewModel()` — 将 UI 状态同步到 ViewModel
2. `viewModel.saveConfig()` — 写入 Preferences 并 flush

### 3.7 API 密钥加密

- 使用坚果云密码派生 AES-256-GCM 密钥
- 密钥派变：迭代 HMAC-SHA256（非 PBKDF2，HarmonyOS cryptoFramework 不支持）
- 输出格式：`base64(salt[16] + iv[12] + ciphertext + authTag[16])`

### 3.8 Basic Auth

- 手动构造 `Authorization: Basic base64(username:password)` 请求头
- 不使用 `HttpRequestOptions.serverAuthentication` API（更可靠）

### 3.9 自动同步触发条件

```
触发时机: EntryAbility.onCreate
条件:
  1. sync_auto_enabled == true
  2. 若 sync_wifi_only == true，当前网络必须是 WiFi
  3. 距上次同步 >= 15 分钟
```

---

## 四、Persona 系统详解

### 4.1 数据模型

```
Persona {
  id: string           // "ps-" + UUID
  name: string
  description: string
  avatarUri: string
  position: PersonaPosition  // 注入位置
  depth: number              // 默认 4
  createdAt: number
  updatedAt: number
}
```

### 4.2 PersonaPosition 枚举

| 值 | 含义 |
|----|------|
| `Disabled = 0` | 不注入 |
| `BeforeCharacter = 1` | 角色描述之前 |
| `AfterCharacter = 2` | 角色描述之后 |
| `AtDepth = 3` | 指定深度位置 |

### 4.3 数据库变更 (v34 → v35)

- **v34**: 创建 `personas` 表 + `characters` 表新增 `character_default_persona_id` 列
- **v35**: `chats` 表新增 `chat_persona_id` 列

### 4.4 PromptBuilder 中的注入逻辑

`PromptBuilder` 根据 Persona 的 position 和 depth 将人格描述注入到 prompt 中：
- `BeforeCharacter`: 插入到角色描述之前
- `AfterCharacter`: 插入到角色描述之后
- `AtDepth`: 插入到指定深度位置

### 4.5 默认人格选择

- `PersonaSelectionStore` 存储全局默认人格 ID (`default_persona_id_v1`)
- 角色可单独设置默认人格 (`character_default_persona_id`)
- 聊天可单独设置人格 (`chat_persona_id`)
- 优先级: 聊天 > 角色 > 全局默认

---

## 五、关键文件索引

### 同步相关

| 文件 | 职责 |
|------|------|
| `services/sync/WebDavSyncService.ets` | 同步主逻辑：上传/下载/双向/增量比对 |
| `services/sync/SyncDataExporter.ets` | 导出：逐表导出 + 偏好设置 + API密钥 + 图片列表 |
| `services/sync/SyncDataImporter.ets` | 导入：逐表导入(latest-wins) + 偏好设置 + API密钥 + 图片 |
| `network/webdav/WebDavClient.ets` | WebDAV 协议操作 + 二进制上传/下载 |
| `network/webdav/WebDavModels.ets` | 数据模型：SyncManifest, ManifestFileEntry, ImageExportEntry |
| `storage/SyncConfigStore.ets` | 配置持久化 (Preferences)：含本地 manifest 缓存 |
| `viewmodels/SyncViewModel.ets` | 页面状态管理：加载/保存配置、连接测试、同步触发 |
| `pages/SyncSettingsPage.ets` | 同步设置 UI：表单 + Toggle + 进度 |
| `utils/CryptoHelper.ets` | AES-256-GCM 加密/解密 |
| `network/core/HarmonyHttpClient.ets` | HTTP 客户端：Basic Auth 手动请求头 + customMethod |
| `network/core/HttpClient.ets` | HTTP 抽象接口：ServerAuth, HttpMethod 扩展 |

### Persona 相关

| 文件 | 职责 |
|------|------|
| `models/Persona.ets` | Persona 数据模型 + 创建/校验/更新函数 |
| `models/PersonaPosition.ets` | PersonaPosition 枚举 + 转换函数 |
| `repositories/PersonaRepository.ets` | 数据库 CRUD |
| `repositories/PersonaRepositoryMapper.ets` | ResultSet ↔ Persona 映射 |
| `services/PersonaService.ets` | 业务逻辑：CRUD + 默认人格 |
| `storage/PersonaSelectionStore.ets` | 全局默认人格 ID 持久化 |
| `viewmodels/PersonaViewModel.ets` | 页面状态管理 |
| `pages/PersonaListPage.ets` | 人格列表页 |
| `pages/PersonaEditPage.ets` | 人格编辑页 |

### 基础设施

| 文件 | 变更 |
|------|------|
| `database/DatabaseConstants.ets` | 新增 TABLE_PERSONAS, COLUMN_PERSONA_*, COLUMN_CHAT_PERSONA_ID |
| `database/DatabaseSchema.ets` | 新增 CREATE_PERSONAS_TABLE, v34/v35 迁移 DDL |
| `database/DatabaseMigration.ets` | 注册 v34/v35 迁移 |
| `services/AppServices.ets` | 注册 SyncConfigStore, WebDavSyncService |
| `entryability/EntryAbility.ets` | 自动同步触发 |
| `resources/base/element/string.json` | 同步相关中文文案 (23条) |
| `resources/base/profile/main_pages.json` | 新增 PersonaListPage, PersonaEditPage, SyncSettingsPage 路由 |

---

## 六、已知限制与待优化项

| 问题 | 说明 |
|------|------|
| **无删除同步** | 导入只会新增/更新行，远端删除不会传播到本地 |
| **无并发锁** | 多设备同时同步可能产生冲突，当前仅靠 latest-wins |
| **密钥派变强度** | 迭代 HMAC-SHA256 次数较低，cryptoFramework 不支持 PBKDF2 |
| **avatar_uri 跨设备** | 存储为 `file://` + 绝对沙箱路径，不同设备 UID 不同时路径会失效 |
| **v1 格式兼容** | 导入仍支持 v1 单文件格式，但已不再产出；未来可移除 |
| **双向同步简化** | 当前双向同步实际只做上传（若同设备且时间一致则跳过）；未做真正的三方合并 |
| **图片目录递归创建** | `ensureDirectory` 逐级创建，目录层级深时可能有多次 PROPFIND/MKCOL 请求 |

---

## 七、SyncConfigStore 完整键名表

| Preferences Key | 类型 | 默认值 | 说明 |
|-----------------|------|--------|------|
| `sync_server_url` | string | `https://dav.jianguoyun.com/dav/` | WebDAV 服务器地址 |
| `sync_username` | string | `''` | 坚果云用户名 |
| `sync_app_password` | string | `''` | 坚果云应用密码 |
| `sync_remote_path` | string | `/ArkTavernSolo/` | 远程目录路径 |
| `sync_auto_enabled` | boolean | `false` | 启动时自动同步 |
| `sync_wifi_only` | boolean | `true` | 仅 WiFi 自动同步 |
| `sync_last_sync_time` | string | `''` | 上次同步时间 (ISO) |
| `sync_device_id` | string | 自动生成 | 设备唯一标识 |
| `sync_last_manifest` | string | `''` | 上次同步的 manifest JSON (增量比对用) |

---

## 八、导入时的 Boolean Preferences 白名单

以下键在导入时使用 `putBoolean()`，其余使用 `putString()`：

| 键名 | 说明 |
|------|------|
| `sync_auto_enabled` | ⚠️ 导入时被排除，不从云端覆盖 |
| `sync_wifi_only` | ⚠️ 导入时被排除，不从云端覆盖 |
| `status_instruction_enabled` | 状态栏指令提示开关 |
| `memory_auto_summary_enabled` | 记忆自动摘要开关 |
| `chat_smart_grip_enabled` | 聊天智能抓手开关 |

---

## 九、WebDAV 请求方法映射

| 操作 | HTTP Method | 说明 |
|------|-------------|------|
| 检查连接 | `GET` | 请求 WebDAV 根路径，状态码 200-399 为成功 |
| 创建目录 | `MKCOL` | 逐级创建，已存在则跳过 |
| 列出目录 | `PROPFIND` | Depth: 1，解析 multistatus XML |
| 上传文件 | `PUT` | 文本内容直接 PUT |
| 下载文件 | `GET` | 返回文本字符串 |
| 上传图片 | `PUT` | 二进制 `fileIo` 读取后直接 PUT |
| 下载图片 | `GET` | 二进制写入本地 `fileIo` |
| 删除 | `DELETE` | — |
| 移动/重命名 | `MOVE` | — |

> 注意：PROPFIND/MKCOL 等非标准方法通过 `HttpRequestOptions.customMethod` 字段设置（API 23+）
