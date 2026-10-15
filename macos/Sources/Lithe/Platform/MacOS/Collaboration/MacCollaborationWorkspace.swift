import Foundation
import CryptoKit

/// Journal lives in Application Support, never in the installation or a shared
/// worktree cache. Each native document write retains its encoding and CAS guard.
struct MacCollaborationWorkspace: CollaborationWorkspaceEditing {
    let files: any FileStorage
    let documents: any WorkspaceFileOperations
    private static let limit = 16 * 1024 * 1024

    func loadSession(workspace: URL) throws -> Data? {
        let url = journal(workspace).deletingLastPathComponent().appendingPathComponent("session.json")
        guard files.fileExists(at: url) else { return nil }
        let data = try files.readPrefix(from: url, byteCount: Self.limit + 1)
        guard data.count <= Self.limit else { throw CollaborationFailure.invalidState }
        return data
    }
    func saveSession(_ data: Data?, workspace: URL) throws {
        let url = journal(workspace).deletingLastPathComponent().appendingPathComponent("session.json")
        if let data {
            guard data.count <= Self.limit else { throw CollaborationFailure.invalidState }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.writeData(data, to: url, options: .atomic)
        } else if files.fileExists(at: url) { try files.removeItem(at: url) }
    }

    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile] {
        guard paths.count <= 100 else { throw CollaborationFailure.invalidState }
        var size = 0
        return try Set(paths).sorted().map { path in
            let document = try documents.readDocumentDetails(from: resolve(path, workspace: workspace), encoding: nil)
            let count = document?.text.utf8.count ?? 0
            size += count
            guard count <= 2 * 1024 * 1024, size <= Self.limit else { throw CollaborationFailure.invalidState }
            return CollaborationFile(path: path, text: document?.text)
        }
    }

    func pending(workspace: URL) throws -> CollaborationPendingWrite? {
        let location = journal(workspace)
        guard files.fileExists(at: location) else { return nil }
        let data = try files.readPrefix(from: location, byteCount: Self.limit * 4 + 1)
        guard data.count <= Self.limit * 4 else { throw CollaborationFailure.invalidState }
        return try JSONDecoder().decode(CollaborationPendingWrite.self, from: data)
    }

    func prepareHumanFile(path: String, workspace: URL) throws {
        let url = try resolve(path, workspace: workspace)
        guard try documents.readDocumentDetails(from: url, encoding: nil) == nil else { return }
        switch try documents.writeDocumentText("", to: url, expectedContent: nil, encoding: .utf8, expectedIdentity: nil) {
        case .saved: break
        case .conflict: throw AgentEditRestoreError.changed
        }
    }

    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws {
        guard try pending(workspace: workspace) == nil else { throw CollaborationFailure.invalidState }
        let receipt = intent.receipt
        // Validate every path and baseline before writing the durable recovery intent.
        for before in receipt.before {
            let current = try documents.readDocumentDetails(from: resolve(before.path, workspace: workspace), encoding: nil)
            guard current?.text == before.text else { throw AgentEditRestoreError.changed }
        }
        for after in receipt.after { _ = try resolve(after.path, workspace: workspace) }
        let data = try JSONEncoder().encode(intent)
        guard data.count <= Self.limit * 4 else { throw CollaborationFailure.invalidState }
        let location = journal(workspace)
        try files.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.writeData(data, to: location, options: .atomic)
        for after in receipt.after {
            guard let before = receipt.before.first(where: { $0.path == after.path }) else { throw CollaborationFailure.invalidState }
            try replace(path: after.path, expected: before.text, replacement: after.text, workspace: workspace)
        }
        // Keep the journal until the feature owner persists its receipt and plan.
    }

    func finish(workspace: URL) throws {
        let location = journal(workspace)
        if files.fileExists(at: location) { try files.removeItem(at: location) }
    }

    func rollback(workspace: URL) throws {
        guard let intent = try pending(workspace: workspace) else { return }
        // Check the whole recovery before changing any file. An external edit
        // blocks recovery; never replace it with an old whole-file snapshot.
        for before in intent.receipt.before {
            let current = try snapshot(paths: [before.path], workspace: workspace)[0]
            guard let after = intent.receipt.after.first(where: { $0.path == before.path }),
                  current.text == before.text || current.text == after.text else { throw AgentEditRestoreError.changed }
        }
        for before in intent.receipt.before.reversed() {
            let current = try snapshot(paths: [before.path], workspace: workspace)[0]
            if current.text != before.text {
                try replace(path: before.path, expected: current.text, replacement: before.text, workspace: workspace)
            }
        }
        try finish(workspace: workspace)
    }

    private func replace(path: String, expected: String?, replacement: String?, workspace: URL) throws {
        let url = try resolve(path, workspace: workspace)
        let current = try documents.readDocumentDetails(from: url, encoding: nil)
        guard current?.text == expected else { throw AgentEditRestoreError.changed }
        if let replacement {
            switch try documents.writeDocumentText(replacement, to: url, expectedContent: expected,
                encoding: current?.encoding ?? .utf8, expectedIdentity: current?.identity) {
            case .saved: break
            case .conflict: throw AgentEditRestoreError.changed
            }
        } else if let identity = current?.identity {
            guard case .trashed = try documents.trashDocument(at: url, expectedIdentity: identity) else {
                throw AgentEditRestoreError.changed
            }
        } else if current != nil { throw AgentEditRestoreError.incomplete }
    }

    private func resolve(_ path: String, workspace: URL) throws -> URL {
        guard CollaborationWorkflow.isRelativePath(path) else { throw AgentEditRestoreError.outsideWorkspace }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let lexical = workspace.appendingPathComponent(path)
        let url = lexical.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(lexical.lastPathComponent)
        guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count,
              url.resolvingSymlinksInPath() == url else { throw AgentEditRestoreError.outsideWorkspace }
        // New files require an existing directory; a package cannot create an
        // arbitrary directory tree as a side effect of requesting a snapshot.
        guard files.metadata(for: url.deletingLastPathComponent())?.isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func journal(_ workspace: URL) -> URL {
        let identity = SHA256.hash(data: Data(workspace.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return files.applicationSupportDirectory().appendingPathComponent("Lithe/Collaboration/\(identity)/pending.json")
    }
}
