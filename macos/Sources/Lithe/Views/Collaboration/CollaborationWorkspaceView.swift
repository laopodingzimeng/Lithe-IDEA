import SwiftUI

/// Keeps the existing editor mounted while the task dock expands or collapses.
/// Streaming text is observed by individual previews, not by EditorAreaView.
struct CollaborationWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: CollaborationFeatureModel
    @ObservedObject var presentation: CollaborationPresentationModel
    @State private var expandedID: String?
    @State private var floatingID: String?
    private var hasTasks: Bool { feature.plan != nil && !presentation.tasks.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if feature.plan != nil { activityBar }
            LitheSplitPaneView(axis: .vertical, placement: .trailing,
                defaultSize: 192, minimum: 120, maximum: 320, flexibleMinimum: 160,
                clipsSizedPane: true, isSizedPaneCollapsed: !hasTasks || presentation.dockCollapsed,
                sized: { taskDock }, flexible: {
                    EditorAreaView()
                        .overlay {
                            if let preview = presentation.tasks.first(where: { $0.id == expandedID }) {
                                CollaborationDraftPreview(preview: preview, open: {
                                    open(preview)
                                }, close: { expandedID = nil })
                                .background(LitheTheme.editor)
                            }
                        }
                })
        }
        .background {
            if let preview = presentation.tasks.first(where: { $0.id == floatingID }) {
                CollaborationPreviewWindow(preview: preview, onOpen: { open(preview) }, onClose: { floatingID = nil })
                    .frame(width: 0, height: 0)
            }
        }
        .task(id: presentation.navigation) {
            guard let navigation = presentation.navigation, presentation.followsActivity else { return }
            if model.focusedEditorDocument?.isDirty != true { expandedID = nil }
            await model.followCollaborationTarget(navigation.path)
        }
        .onAppear { feature.bind(workspace: model.workspaceURL) }
        .onChange(of: model.workspaceURL) { feature.bind(workspace: $0) }
        .onChange(of: presentation.editingRevision) { _ in expandedID = nil }
        .onChange(of: feature.plan?.id) { _ in expandedID = nil; floatingID = nil }
        .onChange(of: presentation.selectedID) { id in
            if presentation.followsActivity, expandedID != nil { expandedID = id }
        }
        .onChange(of: presentation.tasks.map(\.id)) { _ in
            floatingID = nil
            expandedID = presentation.followsActivity && model.focusedEditorDocument?.isDirty != true ? presentation.selectedID : nil
        }
        .accessibilityIdentifier("collaboration-workspace")
    }

    private var activityBar: some View {
        HStack(spacing: 10) {
            Text(feature.plan?.paused == true ? "由你掌控" : "协作进行中")
                .foregroundStyle(feature.plan?.paused == true ? LitheTheme.warning : LitheTheme.accent)
            Text(feature.plan?.step?.title ?? "确认计划").lineLimit(1).foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 4)
            Button(presentation.followsActivity ? "正在跟随" : "继续跟随") {
                if presentation.followsActivity { presentation.userDidEdit() }
                else {
                    presentation.follow()
                    if let path = presentation.selected?.paths.first ?? feature.plan?.step?.targets.first?.path {
                        presentation.requestOpen(path)
                    }
                }
            }.buttonStyle(.plain).foregroundStyle(LitheTheme.secondaryText)
            if hasTasks {
                Button(presentation.dockCollapsed ? "展开任务" : "收起任务") { presentation.dockCollapsed.toggle() }
                    .buttonStyle(.plain)
            }
            Button("我来写") { feature.takeOver(); expandedID = nil }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 9, height: 26, fontSize: 11))
                .disabled(feature.plan?.phase == .draft || feature.plan?.phase == .complete || feature.plan?.paused == true)
            if let core = feature.plan?.steps.first(where: { $0.owner == .human })?.targets.first {
                Button("打开核心") { feature.takeOver(); expandedID = nil; model.openCollaborationTarget(core.path) }
                    .buttonStyle(.plain).foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .font(LitheTheme.uiFont(size: 11)).padding(.horizontal, 12).frame(height: 36)
        .background(LitheTheme.sidebar)
    }

    private var taskDock: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 1) {
                ForEach(presentation.tasks) { preview in
                    CollaborationTaskCard(preview: preview, selected: presentation.selectedID == preview.id,
                        select: { presentation.select(preview.id) },
                        expand: { presentation.select(preview.id); expandedID = preview.id },
                        float: { floatingID = preview.id }, open: { open(preview) })
                    .frame(width: presentation.tasks.count == 1 ? 480 : 310)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
        .litheScrollViewChrome().background(LitheTheme.panelBorder)
    }

    private func open(_ preview: CollaborationTaskPreview) {
        guard let path = preview.paths.first else { return }
        presentation.select(preview.id)
        model.openCollaborationTarget(path)
        expandedID = nil
    }
}

private struct CollaborationTaskCard: View {
    @ObservedObject var preview: CollaborationTaskPreview
    let selected: Bool
    let select: () -> Void
    let expand: () -> Void
    let float: () -> Void
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: select) {
                    Text(preview.paths.first.map { ($0 as NSString).lastPathComponent } ?? "只读分析")
                        .lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain)
                Spacer(minLength: 4)
                Button(preview.minimized ? "展开" : "收起") { preview.minimized.toggle() }.buttonStyle(.plain)
                Button("放大", action: expand).buttonStyle(.plain)
                Button("小窗", action: float).buttonStyle(.plain)
            }
            .font(LitheTheme.uiFont(size: 11, weight: .semibold)).padding(10)
            HStack {
                Text(preview.state.rawValue).foregroundStyle(preview.state == .written ? LitheTheme.success : LitheTheme.secondaryText)
                if selected { Text("· 当前查看").foregroundStyle(LitheTheme.secondaryText) }
                Spacer()
                if preview.state == .written { Button("打开文件", action: open).buttonStyle(.plain).foregroundStyle(LitheTheme.accent) }
            }.font(LitheTheme.uiFont(size: 10)).padding(.horizontal, 10).padding(.bottom, 8)
            if !preview.minimized {
                Divider()
                CollaborationDraftCode(preview: preview, compact: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top).background(LitheTheme.editor)
    }
}

struct CollaborationDraftPreview: View {
    @ObservedObject var preview: CollaborationTaskPreview
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.paths.joined(separator: " · ")).lineLimit(1).truncationMode(.middle)
                    Text(preview.state == .written ? "已写入项目 · 请在主编辑器审阅" : "\(preview.state.rawValue) · 只读草稿，尚未写入")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 4)
                if preview.state == .written { Button("打开文件", action: open).buttonStyle(.plain) }
                Button("返回编辑器", action: close).buttonStyle(.plain)
            }.font(LitheTheme.uiFont(size: 11)).padding(12).background(LitheTheme.sidebar)
            Divider()
            CollaborationDraftCode(preview: preview, compact: false)
        }.foregroundStyle(LitheTheme.primaryText).background(LitheTheme.editor)
    }
}

private struct CollaborationDraftCode: View {
    @ObservedObject var preview: CollaborationTaskPreview
    let compact: Bool
    var body: some View {
        // Reuse the native output text renderer's selection, copy and follow-
        // scrolling behavior. This is never a second editable source buffer.
        OutputTextView(output: String(preview.text.suffix(compact ? 8_000 : 64_000)),
            searchRoots: [], fileExists: { _ in false }, emptyMessage: "等待模型返回代码…",
            fontSize: compact ? 10.5 : 12, onOpenLocation: { _, _, _ in })
            .accessibilityIdentifier("collaboration-draft-preview")
    }
}
