import SwiftUI
import LitheGitModule
import LitheLocalHistoryModule

/// Compares only the immutable receipt pair; never reads the live document.
struct CollaborationHistoricalDiff: View {
    let before: String?
    let after: String?
    let path: String
    private var withinBudget: Bool {
        [before ?? "", after ?? ""].allSatisfy { CollaborationNarration.lines($0).count <= 1000 }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(before == nil ? "修改前 · 文件不存在" : "修改前"); Spacer(); Text(after == nil ? "修改后 · 文件不存在" : "修改后") }
                .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText).padding(10)
            if withinBudget {
                DiffPaneView(rows: LocalHistoryDiffBuilder.rows(old: before ?? "", current: after ?? "").map(DiffRow.init),
                    fileExtension: (path as NSString).pathExtension, minimumWidth: 600)
            } else {
                Text("文件超过比较行数预算，以下展示两个完整历史版本。")
                    .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText).padding(8)
                HStack(spacing: 1) {
                    CollaborationHistoricalText(text: before)
                    Divider()
                    CollaborationHistoricalText(text: after)
                }
            }
        }
    }
}

struct CollaborationHistoricalText: View {
    let text: String?
    var lines: ClosedRange<Int>? = nil
    private var displayed: String {
        guard let text else { return "（该版本中文件不存在）" }
        guard let lines else { return text }
        let source = CollaborationNarration.lines(text)
        guard lines.lowerBound > 0, lines.upperBound <= source.count else { return text }
        // Display a bounded excerpt for a highlight action; the full snapshot
        // remains available via the existing before/after controls.
        let end = min(lines.upperBound, lines.lowerBound + 199)
        return source[(lines.lowerBound - 1)..<end].joined(separator: "\n") +
            (end < lines.upperBound ? "\n（仅展示前 200 行，切换修改后可查看完整快照）" : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lines {
                Text("讲解定位：第 \(lines.lowerBound)–\(lines.upperBound) 行")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.accent).padding(.horizontal, 12)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: displayed).font(LitheTheme.codeFont).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.litheScrollViewChrome()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
