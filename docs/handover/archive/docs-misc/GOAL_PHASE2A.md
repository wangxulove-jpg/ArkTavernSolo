# ArkTavernSolo Phase 2A Goal

## 项目路径
`D:\DevEco_studio\ArkTavernSolo`

## 必读文件（开工前一次性读取）
1. `docs/HANDOVER.md` — 完整交接文档（项目全貌、架构约束、代码位置、已知陷阱）
2. `docs/WORLD_BUILDING_ROADMAP.md` — 世界观增强路线图（调研结论、4 个 Phase、数据模型变更）
3. `models/Character.ets` — 当前角色模型（重点看 251-266 行 `buildDefaultCharacterSystemContent`）
4. `services/PromptBuilder.ets` — 提示词构建器（重点看 `PromptBuildContext` 和 `buildPrompt`）
5. `database/DatabaseConstants.ets` — 数据库常量（版本 34）
6. `database/DatabaseSchema.ets` — 看 v34 相关 DDL 和已有迁移模式

## 目标
完成 **Phase 2A：角色卡灵活性修复**，包含 3 个子任务：

### 2A.1 修改 buildDefaultCharacterSystemContent（最小改动，先做）
- `Character.ets:254` — `parts.push('你是' + character.name)` → `parts.push(character.name)`
- 验证：arkts_check → 增量编译 → 确认叙述者角色卡不再生成 "你是Narrator"

### 2A.2 新增 Persona（用户身份）系统
- 新增 `models/Persona.ets` — Persona interface + PersonaPosition enum
- 新增 `models/PersonaPosition.ets` — 注入位置枚举（Disabled/BeforeCharacter/AfterCharacter/AtDepth）
- 数据库 v35：新增 `personas` 表 + `chats` 表新增 `persona_id` 列 + `characters` 表新增 `default_persona_id` 列
- DatabaseConstants / DatabaseSchema / DatabaseMigration 适配
- 新增 `repositories/PersonaRepository.ets` + `PersonaRepositoryMapper.ets`
- 新增 `storage/PersonaSelectionStore.ets` — Persona 选择/锁定状态
- 新增 `services/PersonaService.ets` — 业务逻辑（CRUD + 查找优先级：聊天锁定 > 角色锁定 > 全局默认）
- 修改 `services/PromptBuilder.ets` — 注入 Persona 描述到 prompt
- 修改 `services/MacroReplacer.ets` — Persona.name 替换 {{user}}
- 新增 `viewmodels/PersonaViewModel.ets`
- 新增 `pages/PersonaListPage.ets` + `pages/PersonaEditPage.ets`
- 修改 `pages/AppSettingsPage.ets` — 新增"用户身份"分区
- 修改 `pages/ChatPage.ets` — 更多菜单新增"切换身份"
- 修改 `pages/CharacterEditPage.ets` — 新增"默认身份"选择
- 更新 `main_pages.json`

### 2A.3 角色卡编辑页提示优化
- CharacterEditPage 的 systemPrompt 字段旁增加提示文本
- 提供"叙述者模式"/"多人场景"模板快捷填入按钮

## 约束
- 参照 HANDOVER.md 第 3 节架构约束（分层依赖、编码规则）
- 参照 HANDOVER.md 第 9 节已知陷阱（ChatPage 花括号平衡、@Builder 禁 const 等）
- 数据库迁移只增不改，下一版本号 35
- 不使用 barrel export，直接相对路径导入
- 不使用 any / unknown / as 类型断言
- 每批修改后 arkts_check → 增量编译验证
- 参考目录 `D:\DevEco_studio\ArkTavern-Reference\SillyTavern-release\` 只读，禁止修改

## 完成标准
1. arkts_check 通过所有修改文件
2. entry@default 增量编译成功
3. 角色名为 "Narrator" 时 prompt 不出现 "你是Narrator"
4. Persona 可创建/编辑/删除
5. Persona 可锁定到聊天或角色
6. PromptBuilder 正确注入 Persona 描述
7. {{user}} 宏使用 Persona.name 替换
