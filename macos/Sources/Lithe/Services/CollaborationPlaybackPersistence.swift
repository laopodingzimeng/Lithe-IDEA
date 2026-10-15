import Foundation

/// Presentation persistence is independent from the authoritative write journal.
/// A delayed cursor save cannot overwrite a later cursor from the same session.
actor CollaborationPlaybackPersistence {
    private let editing: any CollaborationWorkspaceEditing
    private var revisions: [URL: UInt64] = [:]
    init(editing: any CollaborationWorkspaceEditing) { self.editing = editing }
    func load(workspace: URL) throws -> CollaborationPlaybackState? {
        guard let data = try editing.loadPlayback(workspace: workspace) else { return nil }
        guard data.count <= 8 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
        let state = try JSONDecoder().decode(CollaborationPlaybackState.self, from: data)
        revisions[workspace] = state.revision
        return state
    }
    func save(_ state: CollaborationPlaybackState, workspace: URL) throws {
        guard state.revision > (revisions[workspace] ?? 0) else { return }
        let data = try JSONEncoder().encode(state)
        guard data.count <= 8 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
        try editing.savePlayback(data, workspace: workspace)
        revisions[workspace] = state.revision
    }
    func clear(workspace: URL) throws {
        try editing.savePlayback(nil, workspace: workspace)
        revisions[workspace] = nil
    }
}
