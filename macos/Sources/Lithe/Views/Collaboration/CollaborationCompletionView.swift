import SwiftUI

struct CollaborationCompletionView: View {
    @ObservedObject var completion: CollaborationCompletionModel
    let targets: [CollaborationTarget]
    let open: (String) -> Void
    let request: (CollaborationTarget) -> Void
    @State private var selectedIndex = 0
    @State private var showsSuggestion = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("辅助补全").font(LitheTheme.uiFont(size: 12, weight: .semibold))
            Text("描述你需要的帮助。建议经你接受后进入编辑器，可用撤销恢复。")
                .foregroundStyle(LitheTheme.secondaryText)
            if !targets.isEmpty {
                HStack {
                    LitheMenu {
                        for index in targets.indices {
                            LitheContextMenuItem.action(label(targets[index]), localizesTitle: false, checked: selectedIndex == index) {
                                selectedIndex = index
                            }
                        }
                    } label: { Text(label(targets[min(selectedIndex, targets.count - 1)])).lineLimit(1).truncationMode(.middle) }
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 26, fontSize: 11))
                    Button("打开") { open(targets[min(selectedIndex, targets.count - 1)].path) }.buttonStyle(.plain)
                }
                TextField("例如：补齐参数检查，保留后面的计算逻辑", text: $completion.instruction)
                    .litheSettingsTextField().disabled(completion.busy)
                HStack {
                    Button(completion.state == .generating ? "正在生成" : "请求建议") {
                        request(targets[min(selectedIndex, targets.count - 1)])
                    }.buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 9, height: 28, fontSize: 11))
                        .disabled(completion.busy || completion.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if completion.state == .generating {
                        Button("取消") { completion.reject() }.buttonStyle(.plain)
                    }
                }
            }
            if let suggestion = completion.suggestion {
                Text(label(suggestion.target)).foregroundStyle(LitheTheme.secondaryText).lineLimit(2)
                DisclosureGroup("建议前后对比", isExpanded: $showsSuggestion) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                        Text("原文").foregroundStyle(LitheTheme.secondaryText)
                        Text(suggestion.before).font(LitheTheme.codeFont).textSelection(.enabled)
                        Divider()
                        Text("建议").foregroundStyle(LitheTheme.accent)
                        Text(suggestion.after).font(LitheTheme.codeFont).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240).litheScrollViewChrome()
                }
                HStack {
                    Button("接受建议") { completion.accept() }
                        .buttonStyle(LithePrimaryButtonStyle(horizontalPadding: 10, height: 28)).disabled(completion.busy)
                    Button("拒绝") { completion.reject() }.buttonStyle(.plain).disabled(completion.busy)
                }
            }
            if let message = completion.message {
                Text(message).foregroundStyle(completion.state == .accepted ? LitheTheme.success : LitheTheme.warning)
            }
        }.font(LitheTheme.uiFont(size: 11))
        .onChange(of: targets) { _ in selectedIndex = 0 }
        .accessibilityIdentifier("collaboration-completion")
    }
    private func label(_ target: CollaborationTarget) -> String {
        target.path + (target.signature.map { " · " + $0 } ?? "")
    }
}
