# Tasks

- [x] Task 1: 修改 `buildSessionPrompt`:保留 `oldSessionSummary` 参数,但输入段标注"仅作背景与连贯性参考,不要重复输出";系统提示词改为"主体 = 当前对话全部章节记忆,旧版仅供连贯参考,禁止重复输出旧版内容,冲突以当前章节为准";删除"合并旧版后重新输出"指令
- [x] Task 2: 修改 `generateSessionMemory`:保持 `oldSession.summary` 作连贯参考传入,其余(软失效旧 session + 插入新记录)不变,更新注释说明"旧版仅作连贯参考,主体为当前章节"
- [x] Task 3: 构建验证(本地 hvigor assembleHap 通过),确认无编译问题

# Task Dependencies
- Task 2 依赖 Task 1(buildSessionPrompt 语义调整)
- Task 3 依赖 Task 1、Task 2