# 工作模式计划（CSV 驱动）

> **开发依据 CSV：** `/Users/mac/product-need/Lithe-IDEA-pi/docs/development/pi-collaboration/tasks.csv`
> **生成原则：** 本计划由 AI 依据 CSV 逐条展开生成。
> **CSV 参照标准：**
> - CSV 是本次开发的唯一事实来源（Source of Truth）
> - 一行 CSV 对应一个独立工作项
> - 若本计划与 CSV 内容冲突，以 CSV 为准
> - AI 不得擅自修改 CSV 中的目标、验收标准、交付标准

## 1. 全局约束

- **总体验收原则：**
  - 每条任务必须同时满足结束验收标准与交付标准
- **默认不提交内容：**
  - 临时文件
  - 日志文件
  - 缓存文件
  - 构建产物
  - 本次任务无关文件

## 2. CSV 参照标准解释

- **CSV 文件路径：** `/Users/mac/product-need/Lithe-IDEA-pi/docs/development/pi-collaboration/tasks.csv`
- **CSV 用途：** 记录本次开发的任务条目、状态、验收口径、交付范围、工具要求
- **CSV 解释规则：**
  1. `status` 用于进度跟踪
  2. `acceptance_criteria` 是结束验收标准
  3. `delivery_criteria` 是交付标准
  4. `submit_files` 是允许提交的文件
  5. `exclude_files` 是必须排除的文件

## 3. 工作项列表

### [P0] Pi SDK 与协议

- **内容：** 固定 SDK；受控工具回调；事件流；取消；跨供应商模型配置；隔离最小验证
- **进度：** done
- **结束验收标准：** 本机真实 SDK 配合确定性服务端完成工具循环、拒绝越界与取消验证
- **交付标准：** bridge 源码、锁文件、协议、定时测试报告
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 真实 Pi 1.2.0：13 项有界测试通过；三种协议、工具循环、取消、独立凭据与 macOS 子进程写隔离；报告 .artifacts/test-stability/pi-bridge.html；P1 原生集成继续。

---

### [P1] 桌面后台进程与文件工具

- **内容：** 平台进程、受控读写、项目查找、逐次修改收据、验证任务与恢复
- **进度：** review
- **结束验收标准：** 主编辑器真实创建修改；脏缓冲区和核心范围受保护；退出清理
- **交付标准：** 原生 adapter、端口、集成测试
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 061e29e2 原生 CI 38731121279 编译和协作测试通过；逐次撤销、接管、隔离验证已有目标工具链证据，运行包与桌面完整流程待 P6/P8。

---

### [P2] 双模型异步演示与回放

- **内容：** 独立演示会话；事实记录；版本快照；章节；播放游标；失败降级
- **进度：** review
- **结束验收标准：** 演示暂停和故障不阻塞开发；历史版本和讲解一致
- **交付标准：** 异步服务、持久化、状态测试
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 061e29e2 原生 CI 38731121279 通过独立讲解、历史版本、角色设置测试；真实 SDK 卡住演示不阻塞开发测试通过，完整桌面验收待 P8。

---

### [P3] 开发维护计划与并行任务

- **内容：** 需求探索；人机任务分工；依赖图；并发预算；文件竞争；人工接管
- **进度：** doing
- **结束验收标准：** 开发维护均有闭环；依赖冲突与取消无迟到写入
- **交付标准：** Core 契约、任务调度、fixtures、测试
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** Core 依赖图与确定性任务组、Pi 只读探索、有限并发和串行提交已编码；889 项 Rust 测试通过。原生任务组回归待 CI。

---

### [P4] 独立供应商设置与诊断

- **内容：** 角色分别绑定供应商和模型；模型发现；各角色能力测试；预算
- **进度：** todo
- **结束验收标准：** 不同端点和凭据正确路由；配置修改对活动操作隔离
- **交付标准：** 设置模型、原生界面、诊断回归
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 用户已授权全部功能，按已确认方案执行

---

### [P5] A 风格工作台与补全

- **内容：** 实时/回放；自动跟随；任务小窗；独立进度；提问；主动补全与接受拒绝
- **进度：** todo
- **结束验收标准：** 用户输入不被抢焦点；核心代码只由接受建议改变；浅暗色可用
- **交付标准：** 桌面布局、控件、交互与快照测试
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 用户已授权全部功能，按已确认方案执行

---

### [P6] 运行包更新与只读资源

- **内容：** 可复现构建；受校验运行包安装、版本切换与回滚；资源复用
- **进度：** todo
- **结束验收标准：** 兼容更新不重打 IDE；活动任务固定版本；bundle 清单不变
- **交付标准：** 构建脚本、资源清单、更新契约、验证
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 用户已授权全部功能，按已确认方案执行

---

### [P7] Windows 对等接入

- **内容：** Tauri 后台、双角色配置、协作面板与展示、进程及文件边界
- **进度：** todo
- **结束验收标准：** 共享协议消费一致；Windows 原生构建与目标平台验证
- **交付标准：** Windows 实现、测试、平台矩阵
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 用户已授权全部功能，按已确认方案执行

---

### [P8] 联调验收与交付

- **内容：** 真实 SDK 全流程；相关门禁；原生 CI；集中打包；下载链接与使用说明
- **进度：** todo
- **结束验收标准：** 验证证据匹配提交；安装包可用；未验证项明确记录
- **交付标准：** 报告、架构笔记、文档、CI 产物
- **会用到的 MCP：** none
- **会用到的工具集：** git; gh; Node; Swift; Cargo; Bun
- **验收 Skill：** develop-lithe; write-stable-tests; agent-notes
- **需提交文件：** integrations/; macos/; windows/; rust/; shared/; scripts/; docs/; .agents/notes/; .github/
- **排除文件：** .artifacts/; node_modules/; target/; .build/; credentials
- **备注：** 用户已授权全部功能，按已确认方案执行


## 4. 最终验收

- [ ] 所有 CSV 条目均已展开到本计划
- [ ] 所有任务状态与 CSV 保持一致
- [ ] 每条任务都定义了结束验收标准
- [ ] 每条任务都定义了交付标准
- [ ] 每条任务都明确了 MCP / 工具集 / 验收 Skill
- [ ] 提交文件与 CSV 中 `submit_files` 一致
- [ ] 排除文件未被错误提交
- [ ] 本计划明确标注了开发依据的 CSV 文件路径
- [ ] 本计划已解释 CSV 参照标准
