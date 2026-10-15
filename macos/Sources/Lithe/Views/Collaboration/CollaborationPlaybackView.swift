import SwiftUI

struct CollaborationPlaybackBar: View {
    @ObservedObject var playback: CollaborationPlaybackModel
    @ObservedObject var presentation: CollaborationPresentationModel
    var body: some View {
        HStack(spacing: 10) {
            Text(playback.mode == .live ? "实时" : "历史回放").foregroundStyle(LitheTheme.accent)
            Text("记录 \(playback.chapters.count) · 已讲解 \(playback.preparedCount) · 已看 \(playback.viewedCount)")
                .foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
            Spacer(minLength: 0)
            if playback.explaining { Text("讲解准备中").foregroundStyle(LitheTheme.secondaryText) }
            Button("上一章") { presentation.userDidEdit(); playback.step(-1) }.buttonStyle(.plain)
            LitheMenu {
                for chapter in playback.chapters {
                    LitheContextMenuItem.action(chapter.title, localizesTitle: false, checked: chapter.id == playback.selectedID) {
                        presentation.userDidEdit(); playback.select(chapter.id)
                    }
                }
            } label: { Text("章节") }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 24, fontSize: 10))
            Button("下一章") { presentation.userDidEdit(); playback.step(1) }.buttonStyle(.plain)
            if playback.mode == .live {
                Button(playback.paused ? "查看记录" : "暂停观看") {
                    presentation.userDidEdit(); playback.pause()
                    if let id = playback.selectedID { playback.select(id) }
                }.buttonStyle(.plain)
            }
            Button("回到实时") { playback.live(); presentation.follow() }.buttonStyle(.plain)
        }
        .font(LitheTheme.uiFont(size: 10)).padding(.horizontal, 12).frame(height: 30)
        .background(LitheTheme.sidebar)
    }
}

struct CollaborationPlaybackInspector: View {
    @ObservedObject var playback: CollaborationPlaybackModel
    @State private var selectedPath: String?
    @State private var showsBefore = false
    private var receipt: CollaborationReceipt? { playback.selectedReceipt }
    private var paths: [String] { Array(Set((receipt?.before ?? []).map(\.path) + (receipt?.after ?? []).map(\.path))).sorted() }
    private var file: CollaborationFile? {
        (showsBefore ? receipt?.before : receipt?.after)?.first { $0.path == (selectedPath ?? paths.first) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(playback.selected?.title ?? "历史记录").font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    Text("只读历史快照 · 查看回放不会影响后台开发")
                        .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Button("补充讲解") { playback.explainSelected() }.buttonStyle(.plain).disabled(playback.explaining)
                Button("返回编辑器") { playback.live() }.buttonStyle(.plain)
            }.padding(12).background(LitheTheme.sidebar)
            Divider()
            if let chapter = playback.selected {
                ScrollView {
                    Text(chapter.narration?.explanation ?? chapter.fact.summary ?? chapter.fact.title)
                        .font(LitheTheme.uiFont(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }.frame(maxHeight: 140).litheScrollViewChrome()
                if chapter.narration != nil {
                    Text("AI 讲解 · 状态以真实修改和验证记录为准")
                        .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText).padding(.horizontal, 12)
                }
            }
            if !paths.isEmpty {
                HStack(spacing: 10) {
                    LitheMenu {
                        for path in paths {
                            LitheContextMenuItem.action(path, localizesTitle: false, checked: path == (selectedPath ?? paths.first)) { selectedPath = path }
                        }
                    } label: { Text(selectedPath ?? paths.first ?? "快照文件").lineLimit(1).truncationMode(.middle) }
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 26, fontSize: 11))
                    Spacer()
                    Button("修改前") { showsBefore = true }.buttonStyle(.plain).foregroundStyle(showsBefore ? LitheTheme.accent : LitheTheme.secondaryText)
                    Button("修改后") { showsBefore = false }.buttonStyle(.plain).foregroundStyle(showsBefore ? LitheTheme.secondaryText : LitheTheme.accent)
                }.padding(10)
                Divider()
                OutputTextView(output: file?.text ?? "（该版本中文件不存在）", searchRoots: [], fileExists: { _ in false },
                    emptyMessage: "空文件", fontSize: 12, onOpenLocation: { _, _, _ in })
            } else {
                Text("本章节没有代码快照。")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText).padding(12)
                Spacer()
            }
        }
        .background(LitheTheme.editor)
        .onAppear { acknowledge() }
        .onChange(of: playback.selectedID) { _ in selectedPath = nil; showsBefore = false; acknowledge() }
    }
    private func acknowledge() { if let id = playback.selectedID { playback.markViewed(id) } }
}
