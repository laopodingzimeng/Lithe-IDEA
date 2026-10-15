import Foundation
import LitheCoreContracts

struct CollaborationFile: Codable, Sendable, Equatable {
    let path: String
    let text: String?
    enum CodingKeys: String, CodingKey { case path, text }
    init(path: String, text: String?) { self.path = path; self.text = text }
    // Core distinguishes explicit null (absence) from an omitted field.
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(path, forKey: .path)
        if let text { try value.encode(text, forKey: .text) } else { try value.encodeNil(forKey: .text) }
    }
}
struct CollaborationChange: Codable, Sendable {
    let target: CollaborationTarget
    let expectedText: String?
    let replacement: String?
    enum CodingKeys: String, CodingKey { case target, expectedText, replacement }
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(target, forKey: .target)
        if let expectedText { try value.encode(expectedText, forKey: .expectedText) } else { try value.encodeNil(forKey: .expectedText) }
        if let replacement { try value.encode(replacement, forKey: .replacement) } else { try value.encodeNil(forKey: .replacement) }
    }
}
struct CollaborationReceipt: Codable, Sendable {
    let planId: String
    let planVersion: UInt64
    let stepId: String
    let before: [CollaborationFile]
    let after: [CollaborationFile]
    let changes: [CollaborationChange]
    var key: String { "\(planId):\(planVersion):\(stepId)" }
}
struct CollaborationPendingWrite: Codable, Sendable {
    let receipt: CollaborationReceipt
    let plan: CollaborationPlan
    let undo: Bool
}

/// Calls only an HTTP text model; it has no Agent or process tools.
protocol CollaborationGenerating: Sendable {
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String
}
struct UnavailableCollaborationGenerator: CollaborationGenerating {
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String { throw CollaborationFailure.unavailable }
}

/// Synchronous bounded commits run while the native editor is held by its owner.
/// Platform adapters own encoding, path validation and the crash-recovery journal.
protocol CollaborationWorkspaceEditing: Sendable {
    func loadSession(workspace: URL) throws -> Data?
    func saveSession(_ data: Data?, workspace: URL) throws
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile]
    func pending(workspace: URL) throws -> CollaborationPendingWrite?
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws
    func finish(workspace: URL) throws
    func rollback(workspace: URL) throws
}
extension CollaborationWorkspaceEditing {
    func loadSession(workspace: URL) throws -> Data? { nil }
    func saveSession(_ data: Data?, workspace: URL) throws { }
}
struct UnavailableCollaborationWorkspace: CollaborationWorkspaceEditing {
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile] { throw CollaborationFailure.unavailable }
    func pending(workspace: URL) throws -> CollaborationPendingWrite? { nil }
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws { throw CollaborationFailure.unavailable }
    func finish(workspace: URL) throws { throw CollaborationFailure.unavailable }
    func rollback(workspace: URL) throws { throw CollaborationFailure.unavailable }
}
