import Foundation

struct CollaborationVerificationResult: Codable, Sendable {
    let executionID: String
    let actionID: String
    let sourceRevision: String
    let outcome: String
    let exitCode: Int32?
    let output: String
}

@MainActor
protocol CollaborationVerifying: Sendable {
    func verify(workspace: URL, actionID: String) async throws -> CollaborationVerificationResult
}

struct UnavailableCollaborationVerifier: CollaborationVerifying {
    func verify(workspace: URL, actionID: String) async throws -> CollaborationVerificationResult {
        throw PiAgentFailure.toolDenied
    }
}
