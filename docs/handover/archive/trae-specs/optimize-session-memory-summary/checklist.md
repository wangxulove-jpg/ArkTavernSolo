# Checklist

- [x] `buildSessionPrompt` 保留 `oldSessionSummary` 参数,输入段标注"仅作背景与连贯性参考,不要重复输出"
- [x] 系统提示词以"当前对话全部章节记忆"为主体,明确"禁止重复输出旧版会话记忆内容,冲突以当前章节为准"
- [x] 已删除"在旧版基础上合并全部章节后重新输出"的指令
- [x] `generateSessionMemory` 仍传 `oldSession.summary` 供连贯参考;旧 session"软失效 + 插入新记录"逻辑保持不变
- [x] 项目编译通过(hvigor assembleHap 无错误)
- [x] 生成会话记忆的调用方(MemoryManagementViewModel)无需改动、行为正常