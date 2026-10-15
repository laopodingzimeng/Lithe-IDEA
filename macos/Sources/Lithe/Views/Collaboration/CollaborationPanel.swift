import SwiftUI
import LitheCoreContracts

/// A focused native tool window: current model, current task, one next action.
/// Source editing stays in the workbench; secondary operations are disclosed.
struct CollaborationPanel: View {
    @ObservedObject var feature: CollaborationFeatureModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: AIProviderDiagnosticsFeatureModel
    let openAISettings: () -> Void
    let importWorkflow: () -> Void
    let openTarget: (String) -> Void
    let generatePlan: () -> Void
    let execute: () -> Void
    let undo: () -> Void
    let rollback: () -> Void
    let runTests: () -> Void
    let copyPrompt: () -> Void
    let openAgent: () -> Void
    let minimize: () -> Void
    @State private var confirmingDiscard = false
    private var provider: AIProviderProfile? { settings.commitMessageAI.activeProvider }
    private var locked: Bool { feature.busy || feature.hasPendingWrite }
    private var canRequest: Bool { provider?.isValid == true && !diagnostics.busy }

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "人机协作", onMinimize: minimize) { EmptyView() }
            modelBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = feature.error { errorMessage(error) }
                    if feature.hasPendingWrite { recovery }
                    if let plan = feature.plan { planContent(plan) }
                    else { requirementContent }
                    Divider()
                    management
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome()
            Divider()
            actionFooter
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.editor)
        .onAppear { diagnostics.bind(provider) }
        .onChange(of: provider) { diagnostics.bind($0) }
        .onDisappear { diagnostics.cancel() }
        .alert("结束当前计划？", isPresented: $confirmingDiscard) {
            Button("取消", role: .cancel) {}
            Button("结束计划", role: .destructive) { feature.discard() }
        } message: {
            Text("清除本项目的协作进度和结果记录，代码文件保持当前内容。")
        }
        .accessibilityIdentifier("collaboration-panel")
    }

    private var modelBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前协作模型").font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("模型设置", action: openAISettings).buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
            }
            LitheMenu {
                for candidate in settings.commitMessageAI.providers {
                    LitheContextMenuItem.action(candidate.model + " · " + candidate.name,
                        localizesTitle: false, checked: candidate.id == provider?.id) {
                        settings.selectCommitMessageProvider(candidate.id)
                    }
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("配置服务商与模型…", action: openAISettings)
            } label: {
                HStack(spacing: 8) {
                    Text(provider?.model.isEmpty == false ? provider!.model : "选择或配置模型")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 30, fontSize: 12))
            .disabled(feature.busy || diagnostics.busy)
            .accessibilityIdentifier("collaboration-provider")
            HStack(spacing: 8) {
                Text(provider.map { $0.name + " · " + $0.apiProtocol.title } ?? "先在模型设置中添加服务商")
                    .lineLimit(1).foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
                if diagnostics.busy {
                    ProgressView().controlSize(.small)
                    Button("取消") { diagnostics.cancel() }.buttonStyle(.plain)
                } else {
                    Button("测试连接") { diagnostics.bind(provider); diagnostics.testConnection() }
                        .buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
                        .disabled(provider?.isValid != true || feature.busy)
                }
            }.font(LitheTheme.uiFont(size: 10))
            if diagnostics.connectionState == .ready {
                Text("连接测试通过 · 短消息已返回").font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.success)
            }
            if let error = diagnostics.connectionError {
                Text(error).font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.warning).textSelection(.enabled)
            }
        }
        .padding(14)
        .background(LitheTheme.sidebar)
    }

    private var requirementContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("你写核心，AI 做配套。").font(LitheTheme.uiFont(size: 17, weight: .semibold))
            hint("先描述开发或维护目标，我帮你拆出计划与配套工作，再由你确认分工。")
            Text("这次要做什么").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $feature.requirementText)
                    .font(LitheTheme.uiFont(size: 12)).scrollContentBackground(.hidden).padding(6)
                if feature.requirementText.isEmpty {
                    Text("描述目标，以及你想亲自实现的核心逻辑…")
                        .foregroundStyle(LitheTheme.tertiaryText).padding(11).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 120, maxHeight: 180)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius).strokeBorder(LitheTheme.panelBorder))
            .disabled(locked)
            .accessibilityIdentifier("collaboration-requirement")
            LitheSettingsCheckbox(isOn: $feature.includeEditorContext, title: "附带已打开的项目代码").disabled(locked)
            hint(feature.includeEditorContext
                 ? "最多 8 个文件，总计 24,000 字符。只发送已打开的项目代码。"
                 : "本次只分析需求。生成后补充文件范围，再开始执行。")
            hint("协作使用模型默认思考设置。")
            if feature.workspaceURL == nil { hint("先打开项目，再开始协作。") }
        }
    }

    @ViewBuilder private func planContent(_ plan: CollaborationPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("步骤 \(plan.currentStep + 1) / \(plan.steps.count)")
                Spacer()
                Text(plan.paused ? "已暂停" : plan.phase.title)
            }.font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText)
            Text(feature.workflow?.title ?? "协作计划").font(LitheTheme.uiFont(size: 17, weight: .semibold))
            hint(nextInstruction(plan))
        }
        if plan.phase == .draft {
            steps(plan)
            DisclosureGroup("需求与计划调整") {
                VStack(alignment: .leading, spacing: 10) {
                    hint(plan.requirement)
                    TextEditor(text: $feature.workflowDraftText).font(LitheTheme.codeFont).frame(minHeight: 180)
                    secondary("应用计划修改") { feature.applyDraft() }
                }.padding(.top, 8)
            }
        } else {
            DisclosureGroup("查看完整分工") { steps(plan).padding(.top, 8) }
        }
        if let step = plan.step, plan.phase != .draft, plan.phase != .complete { currentStep(step, plan: plan) }
        if plan.phase == .complete { hint("本次计划已完成。代码和修改记录可继续审阅。") }
    }

    private func steps(_ plan: CollaborationPlan) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text(index < plan.currentStep || plan.phase == .complete ? "✓" : String(format: "%02d", index + 1))
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .foregroundStyle(index < plan.currentStep ? LitheTheme.success : LitheTheme.tertiaryText)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        Text(step.owner == .human ? "你来实现 · 核心逻辑" : "AI 配套")
                            .font(LitheTheme.uiFont(size: 10))
                            .foregroundStyle(step.owner == .human ? LitheTheme.warning : LitheTheme.accent)
                        if let target = step.targets.first {
                            Text(target.path).font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                Divider()
            }
        }
    }

    @ViewBuilder private func currentStep(_ step: CollaborationStep, plan: CollaborationPlan) -> some View {
        Text(step.title).font(LitheTheme.uiFont(size: 14, weight: .semibold))
        if let guidance = feature.workflow?.prompts[step.id], !guidance.isEmpty { hint(guidance) }
        if plan.phase == .ready, !step.questions.isEmpty {
            ForEach(Array(step.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question)
                    TextField("填写本步规则", text: Binding(
                        get: { feature.answers.indices.contains(index) ? feature.answers[index] : "" },
                        set: { if feature.answers.indices.contains(index) { feature.answers[index] = $0 } }))
                        .litheSettingsTextField()
                }
            }
        }
        if !step.targets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("本步文件范围").font(LitheTheme.uiFont(size: 11, weight: .semibold))
                ForEach(Array(step.targets.enumerated()), id: \.offset) { _, target in
                    Button { openTarget(target.path) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.path).font(LitheTheme.uiFont(size: 11, design: .monospaced))
                            if let signature = target.signature { Text(signature).font(LitheTheme.uiFont(size: 10, design: .monospaced)) }
                        }.multilineTextAlignment(.leading)
                    }.buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
                }
            }
        }
        VStack(alignment: .leading, spacing: 7) {
            Text("完成前，核对这些条件").font(LitheTheme.uiFont(size: 11, weight: .semibold))
            ForEach(Array(step.acceptance.enumerated()), id: \.offset) { _, criterion in
                Text("• " + criterion).foregroundStyle(LitheTheme.secondaryText)
            }
        }
        if plan.phase == .review {
            Text(feature.evidence[step.id] ?? "").textSelection(.enabled)
            secondary("需要修改") { feature.perform("requestChanges") }
        }
        if plan.phase == .aiWorking || plan.phase == .checking {
            DisclosureGroup("补充检查记录与手动交接") {
                VStack(alignment: .leading, spacing: 10) {
                    hint("AI 分析不能代替编译与测试。仅记录实际完成的检查。")
                    TextEditor(text: $feature.resultText).font(LitheTheme.uiFont(size: 12)).frame(minHeight: 100)
                    secondary("记录结果，提交验收") { feature.perform("workFinished") }
                        .disabled(feature.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || locked)
                    secondary("复制本步任务说明", action: copyPrompt)
                    secondary("打开 Agent 对话", action: openAgent)
                    hint("普通 Agent 的权限独立于当前计划，复制说明不会限制其写入范围。")
                }.padding(.top, 8)
            }
        }
    }

    private func nextInstruction(_ plan: CollaborationPlan) -> String {
        if plan.paused { return "计划已暂停。恢复后，从当前步骤继续。" }
        switch plan.phase {
        case .draft: return "先确认你与 AI 的职责，确认后再开始实施。"
        case .ready: return plan.step?.questions.isEmpty == false ? "先补全本步规则，再开始实施。" : "范围已确认，准备开始当前步骤。"
        case .aiWorking: return "让 AI 完成配套，再审阅修改结果。"
        case .humanWorking: return "在编辑器中完成核心逻辑并保存，写完后主动交接。"
        case .checking: return "AI 将只读分析你的实现，给出问题位置和建议。"
        case .review: return "审阅结果与验收条件，由你决定是否通过。"
        case .complete: return "本次协作已验收。"
        }
    }

    private var actionFooter: some View {
        VStack(alignment: .leading, spacing: 9) {
            if feature.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(feature.activityTitle).font(LitheTheme.uiFont(size: 11))
                    Spacer(minLength: 0)
                    Button("取消") { feature.cancel() }.buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
                }
                hint("等待当前模型返回；分析与生成最多 180 秒。")
            } else if !feature.hasPendingWrite {
                primaryAction
                if let plan = feature.plan, !plan.paused, plan.phase != .complete {
                    Button("暂停计划") { feature.perform("pause") }
                        .buttonStyle(.plain).font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(LitheTheme.sidebar)
    }

    @ViewBuilder private var primaryAction: some View {
        if let plan = feature.plan {
            if plan.paused { primary("恢复计划") { feature.perform("resume") } }
            else {
                switch plan.phase {
                case .draft: primary("确认计划与分工") { feature.perform("confirm") }
                case .ready:
                    if plan.step?.questions.isEmpty == false {
                        primary("确认本步规则") { feature.perform("resolveQuestions") }
                    } else {
                        primary(plan.step?.owner == .human ? "开始编写核心逻辑" : "开始配套步骤") { feature.perform("start") }
                    }
                case .humanWorking: primary("已保存，交接并检查") { feature.perform("handoff") }
                case .aiWorking: primary("生成配套代码", enabled: canRequest, action: execute)
                case .checking: primary("AI 分析我的实现", enabled: canRequest, action: execute)
                case .review: primary("验收通过，继续") { feature.perform("accept") }
                case .complete: primary("开始新需求") { feature.discard() }
                }
            }
        } else {
            primary(feature.error == nil ? "分析需求，生成计划" : "重新分析需求",
                    enabled: canRequest && feature.workspaceURL != nil && !feature.requirementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: generatePlan)
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先恢复上次未完成的写入").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            hint("核对写入记录后，才能继续当前计划。")
            secondary("核对并完成上次写入") { feature.finishPending() }
            secondary("回退未完成写入", action: rollback)
        }
    }

    private var management: some View {
        DisclosureGroup("记录与管理") {
            VStack(alignment: .leading, spacing: 12) {
                secondary("导入工作流…", action: importWorkflow).disabled(locked || feature.workspaceURL == nil)
                hint("工作流可调整步骤、问题和验收条件。更新 JSON 无需重新安装。")
                secondary("运行项目 Java 测试", action: runTests).disabled(locked || feature.workspaceURL == nil)
                secondary("撤销最近 AI 修改", action: undo)
                    .disabled(locked || feature.receipts.isEmpty || !(feature.plan?.paused == true || feature.plan?.phase == .complete))
                DisclosureGroup("工作流版本") {
                    ForEach(Array(feature.library.enumerated()), id: \.offset) { _, package in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(package.title + " · " + package.version)
                            HStack {
                                secondary("使用此版本") { feature.useInstalled(package) }
                                    .disabled(locked || (feature.plan != nil && feature.plan?.phase != .complete))
                                secondary("移除") { feature.removeInstalled(package) }.disabled(locked)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                DisclosureGroup("AI 修改记录") {
                    ForEach(Array(feature.receipts.enumerated()), id: \.offset) { _, receipt in
                        ForEach(Array(receipt.changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(change.target.path).font(LitheTheme.uiFont(size: 11, weight: .semibold))
                                Text("修改前：\n" + (change.expectedText ?? "（不存在）")).textSelection(.enabled)
                                Text("修改后：\n" + (change.replacement ?? "（删除）")).textSelection(.enabled)
                            }
                        }
                    }
                }
                secondary("重新加载工作流文件") { feature.reloadWorkflow() }
                    .disabled(locked || feature.sourceURL == nil || (feature.plan != nil && feature.plan?.phase != .complete))
                Button("结束并清除当前计划…") { confirmingDiscard = true }
                    .buttonStyle(.plain).foregroundStyle(LitheTheme.error).disabled(locked)
            }.padding(.top, 12)
        }.foregroundStyle(LitheTheme.secondaryText)
    }

    private func errorMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("本次操作未完成").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            Text(message).font(LitheTheme.uiFont(size: 11)).textSelection(.enabled)
            Button("检查模型设置", action: openAISettings).buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LitheTheme.warning).background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).lineLimit(2) }
            .buttonStyle(LithePrimaryButtonStyle(horizontalPadding: 10, height: 32))
            .disabled(!enabled || locked).opacity(enabled && !locked ? 1 : 0.5)
            .accessibilityIdentifier("collaboration-next-action")
    }
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 28, fontSize: 11))
    }
}
