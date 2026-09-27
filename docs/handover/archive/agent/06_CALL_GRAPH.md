# 06 — Call Graph 核心调用链

> 路径省略 `entry/src/main/ets/`。标记：✅已实现 ⚠️部分/待验证。

## 1. 应用启动链 ✅

```
系统 → EntryAbility.onCreate
  → AppServices.initialize(context)
       → modelService.initialize → appPreferences.initialize → themeManager.initialize
       → chatTextStyleSettings.load → dbHelper.initialize → characterService.initialize
       → characterStore.initialize → characterMigrationService.migrateIfNeeded
       → lorebookStore.initialize → lorebookMigrationService.migrateIfNeeded
       → lorebookService.initialize → promptPresetService.initialize → personaService.initialize
       → 创建 ChatBackgroundService / ContextBudgetService / MarketImportService /
          MarketTranslationService / ChatArchiveService(Import) / WebDavSyncService / DeepSeekBalanceService
  → AppServices.whenReady()（页面等待）
  → EntryAbility.triggerAutoSync() → WebDavSyncService.autoSync()
  → onWindowStageCreate → loadContent('pages/Index')
```

## 2. 用户点「发送」✅

```
ChatPage 发送按钮 → viewModel.sendMessage() → ChatService.sendMessage(content, callbacks)
  doStream/internal:
    sendMessage → validateMessages / isGenerating 防重
    → buildEstimateMessages → PromptBuilder.buildPrompt(PromptBuildContext{角色,世界书,记忆,Preset,Persona,历史窗口})
      → LorebookService.scan(匹配关键词) / MacroReplacer.replace / RecentMessageSelector窗口
    → ModelService.streamChat(request, callbacks)
      → DefaultProviderFactory.createOpenAIProvider → OpenAIProvider.streamChat
        → OpenAIStreamSession.open → HttpStreamTransport.start(SSE)
          → SseParser → OpenAiSseDeltaParser → Utf8StreamDecoder(UTF-8 累积解码)
            → onDelta → (reasoning_content 处理) → ChatService 更新 messages（不可变）
              → callbacks.onMessagesChanged → ChatViewModel.flush/节流 → ChatPage UI
        → onComplete → ChatPersistenceService 持久化增量 merge
    → 完成后可选 generateStatusFields / triggerManualMemorySummary
```

## 3. 代写候选（Impersonate）✅

```
ChatPage 点代写 → ChatViewModel.generateImpersonateCandidates()
  → ChatService.generateImpersonateCandidates()
       ├─ 取最近 6 条消息（不走 buildRequestMessages）
       ├─ User/Assistant 角色互换 + 专用 system prompt
       ├─ maxTokens 跟随 effectiveSettings
       └─ ModelService(非流式) → parseImpersonateCandidates("1.\n2.\n3."解析)
  → 结果注入 ImpersonateCandidatesPanel（悬浮面板）
```

## 4. 旁白 Narrator ✅

```
ChatPage(旁白模式) → 选择「📝旁白」(ChatViewModel.sendNarratorOnly)
  → ChatService.narratorMessageOnly(content) → 仅插入旁白消息(includeInMemory=false)
  或 选择「🎬生成」(ChatViewModel.sendNarrator)
  → ChatService.narratorMessage → 创建旁白输入消息 + Assistant占位(senderType='narrator')
  → doStream(注入 NarratorInstruction，guide AI 以旁白视角)
  → 完成 → MessageActionSheet「加入记忆」→ ChatViewModel.markMessageIncludeInMemory(true)
```

## 5. 用户性格总结 ✅

```
ChatPage personaPickerSheet → 「从角色卡提取」=ChatViewModel.extractUserFromCharacter
  → ChatService.extractUserFromCharacter() → ModelService(temperature0.3,maxTokens512,非流式)
  → 「从对话总结」=ChatViewModel.summarizeUserPersona
  → ChatService.summarizeUserPersona()（读全部用户消息,超4000截断）
  → 合并追加 → updateCurrentChatUserPersonaSummary → ChatPersistenceService.updateUserPersonaSummary
  → ChatRepository.update
  下次代写 prompt 注入 {{userName}}性格特征
```

## 6. 消息 Swipe ✅

```
ChatPage 长按/控件 → ChatService.activatePreviousCandidate / activateNextCandidate
  → MessageSwipePersistenceService 持久化激活索引
  → 或 generateAlternativeCandidate → 重新生成 → 写入 message_swipe_candidates
```

## 7. 分支 Fork / 分支地图 ✅

```
ChatMessageActionSheet「从此处创建独立对话」→ ChatViewModel → ForkChatService.forkChat
BranchMapPage → BranchMapViewModel → ConversationBranchPersistenceService(读分支/切active)
ChatService.switchBranch / continueFromAssistant(从Assistant续写)
```

## 8. 云同步 ✅

```
SyncSettingsPage → SyncViewModel → WebDavSyncService.upload/download
  → SyncDataExporter / SyncDataImporter → WebDavClient(网络) → SyncConfigStore(manifest缓存)
  → CryptoHelper(AES-256-GCM 密钥加解密)
```

## 9. 角色卡导入（V1/V2/V3/PNG）✅

```
CharacterListPage/AddCharacterPage → 选择文件
  → parser 层判断：JSON→CharacterCardJsonParser / PNG→PngCharacterCardParser(读tEXt ccv3/chara)
  → CharacterService.importParsedCharacterCard
  → CharacterRepository.insert → CharacterAssetStore(头像) → 完成
  → 角色卡 book 自动导入 lorebook
```

## ⚠️ 未完成 / 待验证

- 代写候选面板点击（HitTestMode）待真机验证（见 09）
- 旁白/续写/记忆过滤的实机行为待综合验证
- 群聊/多角色交互：数据模型枚举已预留（`models/ConversationMode.ets`、`GroupReplyModeSetting`、`chat_participants` 表），但 UI 未完整实现 —— 见 `docs/WORLD_BUILDING_ROADMAP.md` Phase 3