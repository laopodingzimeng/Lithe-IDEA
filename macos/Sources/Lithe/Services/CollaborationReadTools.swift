import Foundation

/// Bounded source exploration through the document port, off the main actor.
/// The workspace feature supplies its existing inventory; no second index exists.
struct CollaborationReadTools: Sendable {
    let editing: any CollaborationWorkspaceEditing
    let workspace: URL
    let catalog: [String]

    func perform(_ request: PiToolRequest) async throws -> Data {
        try Task.checkCancellation()
        switch request.name {
        case "workspace_list":
            struct Result: Encodable { let paths: [String]; let nextCursor: String? }
            let paths = try scopedPaths(request.arguments.directory)
            let offset = Int(request.arguments.cursor ?? "0") ?? -1
            guard offset >= 0, offset <= paths.count else { throw PiAgentFailure.toolDenied }
            let end = min(offset + 100, paths.count)
            return try JSONEncoder().encode(Result(paths: Array(paths[offset..<end]), nextCursor: end < paths.count ? String(end) : nil))
        case "workspace_read":
            guard let target = request.arguments.target, CollaborationPlanningContext.canShare(target.path),
                  catalog.contains(target.path) else { throw PiAgentFailure.toolDenied }
            let file = try editing.snapshot(paths: [target.path], workspace: workspace)[0]
            struct Result: Encodable {
                let file: CollaborationFile
                let target: CollaborationTarget
                let truncated: Bool
                let contentScope = "wholeFile"
            }
            let limit = 256_000
            return try JSONEncoder().encode(Result(file: CollaborationFile(path: file.path, text: file.text.map { String($0.prefix(limit)) }),
                target: target, truncated: (file.text?.count ?? 0) > limit))
        case "workspace_search":
            guard let query = request.arguments.query, !query.isEmpty, query.count <= 512 else { throw PiAgentFailure.toolDenied }
            struct Match: Encodable { let path: String; let line: Int; let text: String }
            struct Result: Encodable { let matches: [Match]; let truncated: Bool }
            let paths = try scopedPaths(request.arguments.directory)
            var matches: [Match] = [], scanned = 0, truncated = false
            for path in paths {
                try Task.checkCancellation()
                guard scanned < 4 * 1024 * 1024, matches.count < 100 else { truncated = true; break }
                guard let source = try editing.snapshot(paths: [path], workspace: workspace)[0].text else { continue }
                let sample = String(source.prefix(min(256_000, 4 * 1024 * 1024 - scanned)))
                scanned += sample.utf8.count
                if sample.count < source.count { truncated = true }
                for (index, line) in sample.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    guard matches.count < 100 else { truncated = true; break }
                    if line.contains(query) { matches.append(Match(path: path, line: index + 1, text: String(line.prefix(500)))) }
                }
            }
            return try JSONEncoder().encode(Result(matches: matches, truncated: truncated))
        default: throw PiAgentFailure.toolDenied
        }
    }

    private func scopedPaths(_ directory: String?) throws -> [String] {
        if let directory, !CollaborationPlanningContext.canShare(directory) { throw PiAgentFailure.toolDenied }
        return catalog.filter { path in
            CollaborationPlanningContext.canShare(path) && (directory == nil || path.hasPrefix(directory! + "/"))
        }.sorted()
    }
}
