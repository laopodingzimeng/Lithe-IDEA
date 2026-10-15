import Combine
import Foundation

/// Ephemeral presentation does not grant write authority. Each task owns its
/// draft publications so streaming does not invalidate the whole workbench.
@MainActor
final class CollaborationTaskPreview: ObservableObject, Identifiable {
    enum State: String { case waiting = "等待", generating = "生成草稿", validating = "校验中", written = "已写入", cancelled = "已取消", failed = "未写入", reviewed = "分析完成" }
    let id: String
    let paths: [String]
    @Published var state: State = .waiting
    @Published var text = ""
    @Published var minimized = false
    init(id: String, paths: [String]) { self.id = id; self.paths = paths }
}

@MainActor
final class CollaborationPresentationModel: ObservableObject {
    struct Navigation: Hashable { let id = UUID(); let path: String }
    @Published private(set) var tasks: [CollaborationTaskPreview] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var followsActivity = true
    @Published private(set) var navigation: Navigation?
    @Published private(set) var editingRevision = 0
    @Published var dockCollapsed = false
    var selected: CollaborationTaskPreview? { tasks.first { $0.id == selectedID } }

    func begin(groups: [[CollaborationTarget]]) {
        tasks = groups.enumerated().map { index, targets in
            CollaborationTaskPreview(id: UUID().uuidString + ":" + String(index), paths: Array(Set(targets.map(\.path))).sorted())
        }
        selectedID = tasks.first?.id
        dockCollapsed = false
    }
    func select(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        selectedID = id; followsActivity = false
    }
    func follow() { followsActivity = true }
    func userDidEdit() { followsActivity = false; editingRevision += 1 }
    func requestOpen(_ path: String) {
        guard followsActivity else { return }
        navigation = Navigation(path: path)
    }
    func activity(_ id: String) {
        guard followsActivity, selectedID != id else { return }
        selectedID = id
    }
    func cancel() {
        for task in tasks where [.waiting, .generating, .validating].contains(task.state) { task.state = .cancelled }
    }
    func reset() {
        tasks = []; selectedID = nil; navigation = nil; followsActivity = true; dockCollapsed = false
    }
}

/// Read a replacement string from an incomplete JSON response for a read-only
/// preview. The full response must still decode and pass Core before any write.
enum CollaborationDraftText {
    static func replacement(in text: String) -> String? {
        let bytes = Array(text.utf8.prefix(1_048_576))
        var cursor = 0
        while cursor < bytes.count {
            guard bytes[cursor] == 34 else { cursor += 1; continue }
            let start = cursor
            cursor += 1
            while cursor < bytes.count {
                if bytes[cursor] == 92 { cursor += 2; continue }
                if bytes[cursor] == 34 { break }
                cursor += 1
            }
            guard cursor < bytes.count else { return nil }
            let token = String(decoding: bytes[start...cursor], as: UTF8.self)
            cursor += 1
            guard token == "\"replacement\"" else { continue }
            while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == 58 else { continue }
            cursor += 1
            while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == 34 else { return nil }
            let valueStart = cursor
            cursor += 1
            var safeEnd = cursor
            while cursor < bytes.count {
                if bytes[cursor] == 34 {
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[valueStart...cursor]))
                }
                if bytes[cursor] == 92 {
                    guard cursor + 1 < bytes.count else { break }
                    let length = bytes[cursor + 1] == 117 ? 6 : 2
                    guard cursor + length <= bytes.count else { break }
                    cursor += length
                } else { cursor += 1 }
                safeEnd = cursor
            }
            var partial = Data(bytes[valueStart..<safeEnd]); partial.append(34)
            return try? JSONDecoder().decode(String.self, from: partial)
        }
        return nil
    }
}
