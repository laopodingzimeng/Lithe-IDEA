import Foundation
import LitheCoreContracts

/// Parallelizes only confirmed independent file groups. The caller performs a
/// single Core validation and journaled commit after every child has finished.
struct CollaborationDraftService: Sendable {
    enum Event: Sendable {
        case started(Int)
        case text(Int, String)
        case finished(Int, String)
    }
    let generator: any CollaborationGenerating

    func generate(groups: [[CollaborationTarget]], system: String, prompt: String,
                  context: String, settings: CommitMessageAISettings,
                  onEvent: @escaping @Sendable (Event) -> Void) async throws -> [CollaborationChange] {
        try await withThrowingTaskGroup(of: (Int, [CollaborationChange]).self) { group in
            func enqueue(_ index: Int) {
                let targets = groups[index]
                group.addTask {
                    try Task.checkCancellation()
                    onEvent(.started(index))
                    let scope = String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
                    let response = try await generator.generate(system: system,
                        prompt: prompt + "\n本请求仅授权这些目标（原样复制，不修改其他文件）：" + scope + "\n源码快照：" + context,
                        settings: settings, onText: { onEvent(.text(index, $0)) })
                    try Task.checkCancellation()
                    struct Output: Decodable { let changes: [CollaborationChange] }
                    let changes = try JSONDecoder().decode(Output.self, from: CollaborationResponseJSON.data(response)).changes
                    guard !changes.isEmpty, changes.allSatisfy({ targets.contains($0.target) }) else {
                        throw CollaborationFailure.invalidPackage
                    }
                    onEvent(.finished(index, changes.compactMap(\.replacement).joined(separator: "\n\n")))
                    return (index, changes)
                }
            }
            var next = 0
            while next < min(groups.count, 3) { enqueue(next); next += 1 }
            var results: [(Int, [CollaborationChange])] = []
            while let result = try await group.next() {
                results.append(result)
                if next < groups.count { enqueue(next); next += 1 }
            }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}

enum CollaborationResponseJSON {
    static func data(_ value: String) -> Data {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let first = text.firstIndex(of: "\n"),
           let last = text.range(of: "```", options: .backwards), first < last.lowerBound {
            text = String(text[text.index(after: first)..<last.lowerBound])
        }
        return Data(text.utf8)
    }
}
