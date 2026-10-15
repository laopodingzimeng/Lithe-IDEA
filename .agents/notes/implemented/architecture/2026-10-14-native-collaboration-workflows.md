# Agent 笔记：桌面原生协作与数据工作流

状态：已实现

## 先说结论

协作面板必须在 Lithe 桌面内，用现有编辑器编写代码。已编码的第一阶段支持导入工作流、确认分工、
模型生成计划、受控补丁、只读代码分析、撤销、版本回退与项目进度保存；原生构建验收由 GitHub 执行。
后续调整步骤和提示词只更新 JSON，不要求重新构建 IDE；新增宿主能力仍需升级程序。

## 问题

完整打包耗时，不能让每次工作流调整都触发产品发布。独立浏览器原型不符合用户要求，
现有声明式语言插件也不提供任意原生面板，不能把网页展示误称为桌面扩展。

## 决策

- 固定 SwiftUI 面板提供原生控件；工作流只是有版本的数据包。它没有 JavaScript、shell、
  原生库或任意 UI 组件入口，因此不能绕过宿主添加执行权限。schemaVersion 1 只对应当前字段。
- AppServices 注入计划操作端口，MacServiceContainer 组装 Rust adapter；FeatureModel 持有
  项目状态，View 只展示与提交意图。Core 沿用版本化状态机。FeatureModel 持有可取消的 HTTP Task，
  项目关闭时取消并等待退出，不新增 Agent 进程或 watcher。
- 用户从系统文件对话框显式选择包；读取最多 1 MiB，校验后以 draft 创建计划，不导入包里的运行状态。
  活动计划固定数据快照，更新被拒绝直到完成或用户明确清除。清除只影响计划，不回滚代码。
- 点击文件调用现有文档导航，代码继续使用原生编辑器与保存链路。复制任务说明和打开普通 Agent
  是两个独立人工动作，不会自动发送消息。普通 Agent 权限不受计划约束，界面明确说明。
- 结果是用户填写的实际执行记录，不能伪装成模型分析或测试报告；空结果不能提交验收。
  AI 分析与手填记录不同于编译和测试结果，测试使用现有 Java 测试面板。
- 项目会话和修改记录最多 16 MiB，写入平台 session.json 后再更新兼容用 KeyValueStore 键 `collaboration.native.v1.<workspace-path>`。
  所有权属于当前项目的 FeatureModel；重启未完成任务先暂停，损坏记录保留并阻止覆盖，直到显式清除。
  工作流来源 URL 不持久化，重启后更新需要重新选择文件。尚未提交的答案和结果输入不持久化。
  原生会话现在优先读写平台 Application Support 的 session.json，偏好保留旧格式兼容。
- 模型复用已有 HTTP 生成器的协议与凭据，协作文本请求使用独立的 180 秒上限，不复用拥有工具权限的 ACP Agent。
  需求分析按总计 24,000 字符、每文件 6,000 字符、最多 8 文件采样并标注截断；可关闭代码上下文。
  协作不继承提交功能的 reasoning effort，而使用模型默认行为，避免旧提交设置影响兼容模型。
  生成前后校验工作区、计划版本和取消状态。提交时通过 EditorClosingPreparation 持有编辑器，拒绝 dirty buffer。
- 原生 adapter 在 Application Support/Lithe/Collaboration/<workspace-sha256> 保存 pending.json 与 session.json。
  写入前记录完整意图，每文件复用原生内容/字节身份校验与编码处理。完成后先保存会话再清除意图。
  崩溃后精确匹配全 after 才能完成登记；部分写入仅在每个文件匹配 before 或 after 时回退，其他修改报告冲突。
- 撤销通过 Core reverse 保留其他方法的人工改动。新增文件的撤销进入系统废纸篓；已有文件保留编码。
  新目录不会被模型自动创建，父目录必须已存在。路径与符号链接检查由平台适配器执行。
- 新运行时资源以 collaboration-runtime-state 从 worktree 复用中排除；不写 bundle，不影响代码签名或 Sparkle 基线。
- 安装包内容相同 ID/版本必须相同，最多保留 30 个版本，使用旧版本即回退；活动计划固定数据快照。
  此机制只安装 JSON，不需要信任可执行插件，也不实现在线插件市场。

正确做法：改 JSON 中“负数规则”的问题文字，结束旧计划后在桌面导入新版本。
不要把任意 shell 字段加入包后直接执行，也不要为新工作流改写安装包里的资源。

- A 方案工具窗固定顶部当前模型和底部下一步，主体只展示当前阶段。历史、测试和撤销收进“记录与管理”。
  面板模型切换沿用共享原生菜单，配置编辑仍由既有设置页负责，不另建凭据管理。
  面板与设置各自拥有诊断任务，切换模型、离开面板和项目关闭均取消；保存密钥清除旧测试结果。
- HTTP 超时统一为 URLError.timedOut，HTTPS 同时设置整体资源时限；取消早于 HTTP continuation 注册时立即结束，
  不留下永远等不到的任务。失败保留需求并给出中文重试建议，不自动重复付费调用。没有新增磁盘缓存资源。

## 考虑过的备选方案

- 独立浏览器工作台：可以快速测试，但不是用户要求的桌面功能，已从交付源码撤下。
- WebView 套壳：仍需原生权限桥接，且不满足本次原生交互方向，不采用。
- 任意原生动态库：扩大兼容性、权限与签名负担，当前只需要更新工作流数据。
- 仅把 45 秒超时改成无限等待：不能解决大上下文和隐藏推理参数，采用有限预算、上下文控制和明确重试。
- 每个模板编译到 Swift：无法独立更新，采用外部 JSON 显式导入。

## 后果

菜单和右侧工具栏有明确入口，模板调整不再等待打包。但这不是任意插件框架，
仍不是任意代码插件加载器。原生界面变动和新增执行器仍要构建宿主。
隔离只适用于此 HTTP 模型执行链，普通 Agent 与项目测试不属于这一边界。

## 验证

- `scripts/test-macos.sh --filter CollaborationRequestTests`：上下文边界、独立请求预算、思考参数隔离与超时后重试。
- `scripts/test-macos.sh --filter CollaborationFeatureModelTests`：原生状态、导入锁定、项目隔离与恢复。
- `scripts/verify-service-boundaries.sh`：View、FeatureModel、端口与组合边界。
- `scripts/verify-runtime-bundle-immutability.sh`：macOS 与 Windows 资源只读边界。
- `scripts/verify-agent-notes.sh`：笔记完整性。
- 原生测试本机受到 Swift 6.0.3 与所需 6.3.3 工具链不匹配限制，不能宣称已通过。

## 适用范围

- `macos/Sources/Lithe/Views/Collaboration/CollaborationPanel.swift`
- `macos/Sources/Lithe/Application/Features/CollaborationFeatureModel.swift`
- `macos/Sources/Lithe/Core/Ports/CollaborationWorkflow.swift`
- `shared/contracts/collaboration-workflows.md`
