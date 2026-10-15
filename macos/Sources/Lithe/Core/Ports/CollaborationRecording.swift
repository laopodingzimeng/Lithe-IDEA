import Foundation

/// Facts come from the host, never from model narration. Receipt keys refer to
/// immutable recorded versions; a replay must never fall back to a live file.
struct CollaborationFact: Codable, Sendable, Identifiable {
    let id: String
    let workspaceID: String
    let planVersion: UInt64
    let runID: String
    let taskID: String
    let sourceSequence: UInt64
    let recordedAt: Date?
    let kind: String
    let title: String
    var summary: String? = nil
    var receiptID: String? = nil
    var verificationID: String? = nil
}

struct CollaborationNarration: Codable, Sendable {
    struct Action: Codable, Sendable {
        let type: String
        var path: String? = nil
        var startLine: Int? = nil
        var endLine: Int? = nil
    }
    let schemaVersion: Int
    let sourceEventIDs: [String]
    let snapshotID: String?
    let title: String
    let explanation: String
    let actions: [Action]

    func validate(fact: CollaborationFact, receipt: CollaborationReceipt?) throws {
        guard schemaVersion == 1, sourceEventIDs == [fact.id], snapshotID == fact.receiptID,
              !title.isEmpty, title.count <= 120, explanation.count <= 4000, actions.count <= 4 else {
            throw CollaborationFailure.invalidPackage
        }
        for action in actions {
            guard ["show_file", "show_diff", "highlight_lines"].contains(action.type),
                  let path = action.path, let snapshot = receipt?.after.first(where: { $0.path == path })
                    ?? receipt?.before.first(where: { $0.path == path }) else { throw CollaborationFailure.invalidPackage }
            if action.type == "highlight_lines" {
                let source = snapshot.text ?? receipt?.before.first(where: { $0.path == path })?.text
                guard let source else { throw CollaborationFailure.invalidPackage }
                let count = Self.lines(source).count
                guard let start = action.startLine, let end = action.endLine,
                      start >= 1, end >= start, end <= count else { throw CollaborationFailure.invalidPackage }
            }
        }
    }

    static func lines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

struct CollaborationPlaybackState: Codable, Sendable {
    var revision: UInt64 = 0
    var selectedID: String? = nil
    var viewedIDs: [String] = []
    var narrations: [String: CollaborationNarration] = [:]
}
