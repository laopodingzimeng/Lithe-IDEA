import SwiftUI

/// Native tool window. Source edits stay in Lithe's existing editor and save pipeline.
struct CollaborationPanel: View {
    @ObservedObject var feature: CollaborationFeatureModel
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

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "协作", onMinimize: minimize) {
                Button("导入工作流…", action: importWorkflow)
                    .disabled(feature.workspaceURL == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = feature.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if feature.busy {
                        ProgressView("正在处理…")
                        Button("取消当前操作") { feature.cancel() }
                    }
                    if feature.hasPendingWrite {
                        Text("上次写入尚未完成确认。先恢复，再继续计划。")
                        Button("核对并完成上次写入") { feature.finishPending() }
                        Button("回退未完成写入", action: rollback)
                    }
                    if let workflow = feature.workflow, let plan = feature.plan {
                        Text(workflow.title).font(LitheTheme.uiFont(size: 15, weight: .semibold))
                        Text("工作流版本 \(workflow.version) · \(plan.paused ? "已暂停" : plan.phase.title)")
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text(plan.requirement).textSelection(.enabled)
                        Divider()
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top) {
                                Text(index < plan.currentStep || plan.phase == .complete ? "✓" : "\(index + 1).")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title)
                                    Text(step.owner == .human ? "你来实现" : "AI 配套")
                                        .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if index == plan.currentStep && plan.phase != .complete { Text("当前") }
                            }
                        }
                        Divider()
                        if let step = plan.step {
                            stepContent(step, plan: plan)
                        }
                        if plan.phase != .complete {
                            Button(plan.paused ? "恢复计划" : "暂停计划") {
                                feature.perform(plan.paused ? "resume" : "pause")
                            }
                        }
                    } else {
                        TextEditor(text: $feature.requirementText).frame(minHeight: 110)
                        Text("填写开发或维护需求。分析将使用 AI 设置中的模型，并发送当前打开的项目代码（最多 8 份）。")
                            .foregroundStyle(LitheTheme.secondaryText)
                        Button("分析需求，生成计划", action: generatePlan).disabled(feature.busy || feature.hasPendingWrite)
                        Text("人机协作").font(LitheTheme.uiFont(size: 16, weight: .semibold))
                        Text("导入开发或维护工作流，确认分工，在编辑器中编写核心逻辑，再按步骤交接和验收。")
                        Text("工作流可以调整步骤、问题、提示词和验收条件。更新工作流无需重新安装 Lithe。")
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Divider()
                    Text("AI 使用已有 AI 设置中的模型。核心逻辑由你编写；模型返回的补丁必须通过范围校验。")
                        .foregroundStyle(LitheTheme.secondaryText)
                    Button("运行项目 Java 测试", action: runTests).disabled(feature.busy || feature.hasPendingWrite)
                    Button("撤销最近 AI 修改", action: undo)
                        .disabled(feature.busy || feature.hasPendingWrite || feature.receipts.isEmpty || !(feature.plan?.paused == true || feature.plan?.phase == .complete))
                    DisclosureGroup("已安装工作流与历史版本") {
                        ForEach(Array(feature.library.enumerated()), id: \.offset) { _, package in
                            VStack(alignment: .leading) {
                                Text(package.title + " · " + package.version)
                                HStack {
                                    Button("使用此版本") { feature.useInstalled(package) }
                                        .disabled(feature.busy || feature.hasPendingWrite || (feature.plan != nil && feature.plan?.phase != .complete))
                                    Button("移除") { feature.removeInstalled(package) }.disabled(feature.busy)
                                }
                            }
                        }
                    }
                    DisclosureGroup("AI 修改记录") {
                        ForEach(Array(feature.receipts.enumerated()), id: \.offset) { _, receipt in
                            ForEach(Array(receipt.changes.enumerated()), id: \.offset) { _, change in
                                Text(change.target.path).font(LitheTheme.uiFont(size: 12, weight: .semibold))
                                Text("修改前：\n" + (change.expectedText ?? "（不存在）")).textSelection(.enabled)
                                Text("修改后：\n" + (change.replacement ?? "（删除）")).textSelection(.enabled)
                            }
                        }
                    }
                    Button("重新加载工作流文件") { feature.reloadWorkflow() }
                        .disabled(feature.busy || feature.hasPendingWrite || feature.sourceURL == nil || (feature.plan != nil && feature.plan?.phase != .complete))
                    Button("结束并清除当前计划…") { confirmingDiscard = true }.disabled(feature.busy || feature.hasPendingWrite)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome()
        }
        .font(LitheTheme.smallFont)
        .background(LitheTheme.editor)
        .alert("结束当前计划？", isPresented: $confirmingDiscard) {
            Button("取消", role: .cancel) {}
            Button("结束计划", role: .destructive) { feature.discard() }
        } message: {
            Text("这会清除本项目的协作进度和结果记录，代码文件保持当前内容。")
        }
        .accessibilityIdentifier("collaboration-panel")
    }

    @ViewBuilder
    private func stepContent(_ step: CollaborationStep, plan: CollaborationPlan) -> some View {
        Text("验收条件").font(LitheTheme.uiFont(size: 12, weight: .semibold))
        ForEach(Array(step.acceptance.enumerated()), id: \.offset) { _, criterion in Text("• " + criterion) }
        ForEach(Array(step.targets.enumerated()), id: \.offset) { _, target in
            Button { openTarget(target.path) } label: {
                VStack(alignment: .leading) {
                    Text(target.path)
                    if let signature = target.signature { Text(signature).font(LitheTheme.codeFont) }
                }
            }
        }
        ForEach(Array(step.decisions.enumerated()), id: \.offset) { _, answer in
            Text(answer).textSelection(.enabled)
        }
        if !plan.paused && !feature.busy && !feature.hasPendingWrite {
            switch plan.phase {
            case .draft:
                DisclosureGroup("编辑计划与文件范围") {
                    TextEditor(text: $feature.workflowDraftText).font(LitheTheme.codeFont).frame(minHeight: 220)
                    Button("应用计划修改") { feature.applyDraft() }
                }
                Button("确认计划与分工") { feature.perform("confirm") }
            case .ready:
                if step.questions.isEmpty {
                    Button(step.owner == .human ? "开始编写核心逻辑" : "开始配套步骤") { feature.perform("start") }
                } else {
                    ForEach(Array(step.questions.enumerated()), id: \.offset) { index, question in
                        TextField(question, text: Binding(
                            get: { feature.answers.indices.contains(index) ? feature.answers[index] : "" },
                            set: { if feature.answers.indices.contains(index) { feature.answers[index] = $0 } }
                        ))
                    }
                    Button("确认本步答案") { feature.perform("resolveQuestions") }
                }
            case .humanWorking:
                Text("在左侧代码编辑器中完成当前步骤，保存后主动交接。")
                Button("交接并检查") { feature.perform("handoff") }
            case .aiWorking, .checking:
                Button(plan.phase == .checking ? "AI 分析我的代码" : "执行 AI 配套修改", action: execute)
                Button("复制本步任务说明", action: copyPrompt)
                Button("打开 Agent 对话", action: openAgent)
                Text("普通 Agent 的工具权限独立于此计划；复制任务说明不会限制其写入范围。")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("检查记录（AI 分析不代替编译与测试）")
                TextEditor(text: $feature.resultText).frame(minHeight: 100)
                Button("记录结果，提交验收") { feature.perform("workFinished") }
            case .review:
                Text(feature.evidence[step.id] ?? "").textSelection(.enabled)
                Button("验收通过，继续") { feature.perform("accept") }
                Button("需要修改") { feature.perform("requestChanges") }
            case .complete:
                Text("本计划已完成，可以导入下一份工作流。")
            }
        }
    }
}
