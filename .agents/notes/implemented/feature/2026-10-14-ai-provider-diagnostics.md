# Agent 笔记：服务商模型发现与连接测试

状态：已实现

## 先说结论

服务商页从用户配置的 API 获取模型列表，并用固定短消息测试所选模型能否返回内容。
两项操作有独立状态，不能把列表获取成功当作模型调用成功。
导入配置继续由 Codex 或 Claude 管理，需要独立选模型时显式创建 Lithe 的可编辑副本。
实现已接入桌面，原生回归与真实服务商验收需要分别验证。

## 问题

原设置页只能手工填模型，导入字段禁用且缺少操作指引，401 只显示英文状态码。
页面选择的编辑对象和协作实际使用的服务商可能不同，用户无法直接判断下一步。

## 决策

- 进入已配置的服务商或保存密钥后获取模型，也保留手动刷新；编辑地址不逐字符请求。
  请求保留网关路径前缀，复用原有认证和 HTTP 传输（网络请求适配器）。
  Anthropic 按游标分页，最多 20 页、2000 个模型，每页最多 1 MiB，目录请求每次 15 秒超时。
- 测试复用现有三种生成协议，发送固定短消息，不发送项目代码、不授予工具权限。
  必须解析到实际文本才算成功；45 秒超时、1024 token 输出上限，省略额外推理设置。
  目录不支持时保留手填模型，不能猜测服务商支持的模型或自动选择列表第一项。
- 使用现有可搜索原生选择器，补齐字段标签、“用于协作与提交”动作与中文错误提示。
  401、403、404、429、网络失败分别提示，不展示服务商错误正文或密钥。
- 导入配置允许获取和测试，但不写回 CLI 文件。显式复制时创建独立服务商标识，
  元数据沿用设置存储、密钥沿用安全存储，副本不会自动替换活动服务商。
  未保存的密钥阻止请求，避免屏幕值与实际发出的认证不同。
- FeatureModel 持有可取消任务和操作标识，切换配置或编辑密钥丢弃旧结果，离开页面取消请求。
  改模型保留目录、清除连接成功状态；关闭项目等待当前任务结束。
- 网络端口增加默认 POST 的方法字段以支持 GET。原生传输拒绝自动重定向，
  保持认证信息绑定到用户配置的服务商；已有生成内容和协议保持原样。
- 列表仅存在设置页内存，不新增下载、解压或磁盘缓存目录，因此不增加 worktree 复用资源。
  配置和凭据仍由既有平台存储管理，不写安装包，不改变代码签名和增量更新基线。

正确示例：从列表选择模型后主动测试，收到真实响应才显示可用。
不要在切换服务商后显示旧配置的成功状态，也不要为了改模型直接写回 Codex 文件。

## 考虑过的备选方案

- 只请求模型列表：不能证明生成权限，采用独立模型调用。
- 直接修改导入配置：影响其他工具，采用显式独立副本。
- 另建网络和协议实现：可能偏离实际生成，复用已有传输和编码器。

## 后果

用户能在设置页完成获取、选择、启用和测试。测试可能产生 API 用量，列表依赖服务商支持。
获取超过上限的列表会提示手填，不把截断结果当作完整目录。短消息成功不代表长协作请求一定成功。
协作面板独立模型选择器和原生界面配置仍保留为后续待办。

## 验证

- `scripts/test-macos.sh --filter AIProviderDiagnostics`：协议、认证、分页、取消和旧结果隔离。
- `.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'AIProviderDiagnostics|CommitMessage|ContextMenuCoverage'`：原生回归与单测试计时。
- `scripts/verify-service-boundaries.sh`、`scripts/verify-runtime-bundle-immutability.sh`：分层和发行包只读边界。
- `scripts/verify-agent-notes.sh`：笔记校验。
- 本机 Swift 与仓库工具链不匹配，原生编译和测试交由 GitHub 指定工具链执行；完成前不标记已验证。

## 适用范围

- `macos/Sources/Lithe/Views/App/AIProviderDiagnosticsView.swift`
- `macos/Sources/Lithe/Application/Features/AIProviderDiagnosticsFeatureModel.swift`
- `macos/Sources/LitheAIAssistanceModule/Services/AIProviderDiagnosticsService.swift`
- `macos/Sources/LitheCoreContracts/AI/AIProviderDiagnostics.swift`
