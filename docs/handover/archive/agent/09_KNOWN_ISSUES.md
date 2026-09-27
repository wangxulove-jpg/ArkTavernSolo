# 09 — Known Issues 已知问题 / 技术债

> 归档当前已知问题、临时方案、技术债务。新发现问题追加到此（不直接改业务代码）。
> 更多陷阱与设计决策见 `docs/HANDOVER.md` §8/§9。

## 1. 已知问题（行为/待验证）

| # | 问题 | 状态 | 归属定位 |
|---|------|------|---------|
| 1 | 代写候选面板点击穿透（HitTestMode.BLOCK_HIERARCHY）未在真机验证 | 🟡待真机验证 | `pages/ChatPage.ets`、`components/ImpersonateCandidatesPanel.ets`；备选改 BindSheet |
| 2 | 旁白/续写/记忆过滤的综合真机行为待验证 | 🟡待验证 | `services/ChatService.ets`、`services/MemoryService.ets` |
| 3 | 用户性格总结 prompt 效果可能需迭代（两次提取合并可能过长需截断） | 🟡待迭代 | `ChatService.extractUserFromCharacter/summarizeUserPersona` |
| 4 | 离线/在线 TTS 引擎真机初始化与播放待验证 | 🟡待验证（含未提交改动） | `services/TtsService.ets`、`EdgeTtsService.ets` |
| 5 | `showToast` 已废弃（部分页面用旧 API） | 🟡技术债 | 如 `pages/AiCharacterPreviewPage.ets:287` |

## 2. 设计限制 / 技术债

| # | 债务 | 说明 |
|---|------|------|
| 1 | WebDAV 同步无删除传播 | 导入仅新增/更新，远端删除不落到本地（latest-wins），见 `handoff-sync-persona.md` |
| 2 | WebDAV 双向同步简化 | 实际只做上传（同设备且时间一致则跳过），非真正三方合并 |
| 3 | WebDAV 密钥派生强度 | 迭代 HMAC-SHA256（cryptoFramework 不支持 PBKDF2）次数偏低 |
| 4 | avatar_uri 跨设备失效 | 存 `file://`+绝对沙箱路径，不同设备 UID 不同会失效 |
| 5 | 密钥/密钥残留 | 删除 Provider 配置失败不回滚，密钥可能残留（可接受的已知取舍） |
| 6 | 大量业务逻辑堆在 ChatService | 超大文件（5000+ 行），职责重，新增流程优先拆分服务 |
| 7 | voices/worlds 旧表残留 | 数据库迁移只增不改，已删功能表仍在 |
| 8 | Edge TTS 未提交改动 | 工作区有 `TtsSettingsPage.ets`/`EdgeTtsService.ets` 未提交（开发中） |

## 3. 架构注意（易踩坑，来自 HANDOVER §9）

1. `pages/ChatPage.ets` 约 4400+ 行，改时严格保持花括号平衡
2. `@Builder` 方法内禁止 `const/let`
3. 数据库迁移只增不改；新增列需新增迁移版本（当前 v38，下次 v39）
4. ArkTS：禁 `any`/`unknown`/`as`、禁动态属性、对象字面量需显式类型上下文
5. `senderType='character'` 消息必须填 `senderCharacterId`，否则 MessageRepository 抛 `invalid data`
6. 所有存储键带 `arktavern_solo` 前缀（与完整版 ArkTavern 隔离）
7. `ChatService.currentChat` 是 private，外部走 `getCurrentChat()`
8. `ChatRequest.temperature/topP` 是 number（非 optional）；`ProviderConfig.maxTokens` vs `EffectiveGenerationSettings.maxOutputTokens` 字段名不同
9. `chatFromRow()` 用 `getColumnIndex >= 0` 安全回退兼容旧 schema
10. `ChatGenerationKind` enum 定义在 `services/ChatService.ets`（不在 models）

## 4. 状态回退 / 迁移注意

- SQLite 不支持 DROP COLUMN：以 `include_in_memory`(v37)、`nickname`(v38) 为例的列无法自动回退，但 `DEFAULT` 保证旧行为不变
- 迁移禁止跳版本，必须逐版连续到当前版本