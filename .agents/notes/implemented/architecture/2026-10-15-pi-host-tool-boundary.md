# Agent 笔记：Pi 工具执行与桌面文件权限

状态：已实现

## 先说结论

Pi 负责模型流式调用和工具循环，Lithe 负责真正的文件访问与每次修改记录。
模型配置按角色固定到独立进程，演示角色没有项目工具。macOS 进程在系统隔离配置下启动，
不能直接修改源项目；原生完整流程仍须目标工具链 CI 验证，Node 层通过不等于桌面验收。

## 问题

原有 HTTP 生成器一次返回一组补丁，无法边探索边修改。直接启用 Pi 默认 shell、
write 工具会越过人工核心代码的授权范围，且同一步多次写入会覆盖旧收据身份。

## 决策

- 复用固定 Pi 1.2.0 的完整 AgentSession（模型会话与工具执行循环），不在 Swift 重写。
  自有 JSONL（每行一条 JSON 消息）协议只负责平台通信、取消、预算和角色隔离。
  显式资源加载器关闭默认工具、插件、MCP、技能和个人配置探测。
- 每个模型调用进程固定供应商、协议、模型与凭据。密钥通过 stdin 输入内存凭据存储，
  不进入命令行、环境、会话磁盘记录或错误文本。复用 Pi 公开的 native-provider 认证挂钩，
  为三种接口选择 Bearer、API Key 或无认证；另一种认证头显式移除。认证值按字面传输，
  SDK 自定义头的命令/环境表达式不开放。
- macOS adapter 使用已有 MacManagedProcess 管理整个进程组，stdout 与 stderr 分离。
  系统 sandbox 配置禁止状态目录外的写入，并继承到子进程；Node 权限额外限制读取和进程创建。
  系统 sandbox-exec 已弃用，缺失或启动失败时必须拒绝运行，不能自动退回无隔离启动。
- 工具访问由宿主重新检查。读工具使用已有项目清单与文档端口；写工具检查当前计划版本、
  运行 ID、目标范围、脏缓冲区和原文，再由 Core 准备与文档端口条件写入。
  新的同一工作区内父级符号链接也被拒绝，避免通过路径别名跨越方法所有权。
- 每个 Pi 写工具有独立 operationId，写前持久化 pending.json，写后保存收据再清除意图。
  工具成功不推进步骤；只有 Pi 最终结束后才进入人工验收。取消时已写内容仍登记、可以逐次撤销。
  旧 HTTP 收据保持原键格式；新字段可缺省，不破坏旧项目恢复。
- 进程临时状态位于 Application Support/Lithe/Pi/Sessions，生命周期是一轮模型任务。
  进程树退出后清理；不改写 bundle，不影响代码签名和 Sparkle 增量源文件。
  node_modules 与运行状态均没有可跨工作树复用的身份，资源清单显式拒绝。
- Java 验证复用整个 LanguageTestService 和项目工具链解析器，在缓存中的有界源码副本运行。
  只授权固定 actionId，不接受模型提供的命令。整个测试进程树只能写入该副本所属状态目录；
  测试结果关联副本内容 SHA-256，不能将其声称为用户稍后修改的当前工作区结果。
  副本与 Maven 临时仓库随任务清理，不跨工作树共享；普通测试面板仍保留原来的用户主动执行入口。
- 关键事实与收据在同一 session.json 中保存。撤销后原快照进入归档收据，回放不从活文件补内容。
  独立的 playback.json 只存讲解与观看位置，索引损坏时从收据重建基础章节，不能阻断开发写入。
  每个索引保存都有版本号，迟到保存不能覆盖新游标；详细字段以共享录制契约为准。
- 需求探索也通过 Pi 只读工具完成。工作流 v2 声明全部任务依赖，由 Core 检查循环和权限后
  编译为分批验收的任务组；同文件写入排队，人工作业单独交接。任务组内模型最多八个并发，
  默认三个。每个会话只能写自己的目标，全部工作区工具通过同一队列完成检查、写入和收据保存。
  这保留旧状态机的人工验收边界；代价是某个已就绪任务可能等待同组其他任务验收。
  一个任务失败会取消并等待兄弟任务结束，但已完成的实际修改保持独立收据，不声称整组原子性。
- 演示请求独立排队，最多一批在途、八批待讲解，自动调用有可配置数量预算。手动讲解保留显式优先级，
  即使排队期间自动预算用尽仍可执行。用户问题优先于后台讲解。
- 供应商测试走真实 Pi SDK；开发角色必须完成内存样本的读取与精确修改工具调用，演示角色必须返回
  带随机校验值的 JSON。界面明确标注能力测试未修改项目，不能将模型宣称的成功当作工具支持。
  每个任务固定输出、时间、累计 tokens 预算；累计值在上游回报后检查，不能承诺等于账单费用上限。
  B 的输出必须引用原事件和原快照，不能决定测试状态、扩大权限或移动用户固定的历史位置。
  开发与演示各自选择既有服务商档案和模型覆盖值，不改动 Git 提交消息的活动模型。
- 人工步骤的辅助补全不使用项目工具。Core 的 `collaboration.previewSuggestion` 只计算单个人工目标的
  建议前后文本，不把人工步骤改成 AI 授权。用户明确接受后，编辑器重新检查文档与位置版本，再以
  独立撤销组进入原有输入确认队列。精确换行由已有源文本镜像保留；用户继续打字、重命名或更换计划后，
  旧建议失效。接受只修改未保存缓冲区，保存与交接仍由用户操作，不伪造 AI 写盘收据。
  建议和基线只在内存中存活，拒绝、工作区切换与退出清理，不新增运行时目录或修改发行包。

正确做法：Pi 请求修改映射方法，宿主检查原文后写入并返回真实收据，再允许下一次请求。
不要让 Pi 返回的“已完成”替代收据，也不要把模型发出的 shell 命令交给终端执行。

## 考虑过的备选方案

- 直接运行 Pi CLI 默认工具：可以立即改文件，但绕过核心逻辑保护，拒绝。
- 只把 Pi SDK 的文本接口当作 HTTP 客户端：仍需自己重写完整工具循环，不符合复用原则。
- 为依赖图重写整个编辑状态机：会让权限与恢复拥有两套规则，采用 Core 确定性分组和现有验收状态机。
- 仅使用 Node permission：可以限制 JavaScript API，但不能当作操作系统隔离证据。
- 单步只保留最后一份收据：无法逐次撤销和定位中途失败，采用逐工具持久化。

## 后果

多轮探索与修改有真实工具结果，演示模型可以独立运行。代价是要维护薄协议、平台隔离和进程预算，
且 OS 隔离需要在目标系统验证。Windows 不能照搬 macOS sandbox，也不能把 Job Object 误当文件隔离。
完整 UI、独立运行包更新和验证任务执行属于后续交付步骤，不由此基础边界的测试结果代替。

## 验证

- `node scripts/test-pi-bridge.mjs`：真实 SDK、本地确定性三协议服务端、工具往返、取消、错误脱敏、子进程写隔离。
- `scripts/test-macos.sh --filter CollaborationPlaybackTests`：演示阻塞时开发继续、历史版本固定、无效讲解降级与角色配置独立。
- `scripts/test-macos.sh --filter CollaborationExecutionTests`：多工具收据、逐次撤销和提交过程中接管；需要仓库固定 Swift 工具链。
- `scripts/test-macos.sh --filter CollaborationSchedulingTests`：有界并发、失败取消、写入队列取消。
- `scripts/test-macos.sh --filter CollaborationCompletionTests`：生成与拒绝不写入、接受仅进入缓冲区、迟到建议失效。
- `scripts/probe-macos-monaco.sh --workbench-tests`：真实编辑器接受确认、混合换行与 Unicode 撤销/重做、过期位置和只读拒绝。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core collaboration::tests::`：依赖图、文件竞争与人机所有权。
- `scripts/verify-service-boundaries.sh`：原生层间职责。
- `scripts/verify-runtime-bundle-immutability.sh`：发行资源只读边界。
- `node scripts/test-reuse-worktree-resources.mjs`：拒绝复制 Pi 状态和未封存依赖。

## 适用范围

- `integrations/pi-bridge/`
- `shared/contracts/pi-bridge.md`
- `macos/Sources/Lithe/Core/Ports/PiAgent.swift`
- `macos/Sources/Lithe/Platform/MacOS/Collaboration/MacPiAgentRunner.swift`
- `macos/Sources/Lithe/Application/Features/CollaborationFeatureModel.swift`
