import Foundation
import LitheCoreContracts

extension AppModel {
    func showCollaboration() {
        collaborationFeature.bind(workspace: workspaceURL)
        showToolWindow(.collaboration)
    }

    func importCollaborationWorkflow() {
        showCollaboration()
        guard let url = platformUI.chooseFile(title: "导入协作工作流", prompt: "导入") else { return }
        collaborationFeature.importWorkflow(at: url)
    }

    func openCollaborationTarget(_ relativePath: String) {
        guard let root = workspaceURL, CollaborationWorkflow.isRelativePath(relativePath) else { return }
        // Reuse the existing document navigation and workspace access policy.
        openFile(root.appendingPathComponent(relativePath))
    }
    func generateCollaborationPlan() {
        guard let root = workspaceURL else { return }
        collaborationFeature.bind(workspace: root)
        // Only already-open workspace documents are shared with the selected model.
        let context = documentFeature.editorDocuments.compactMap { document -> String? in
            let prefix = root.standardizedFileURL.path + "/"
            guard document.url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
            let path = String(document.url.standardizedFileURL.path.dropFirst(prefix.count))
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  !["pem", "key", "p12", "pfx", "env"].contains(document.url.pathExtension.lowercased()) else { return nil }
            return path + "\n" + String(document.text.prefix(20000))
        }.prefix(8).joined(separator: "\n\n")
        collaborationFeature.generatePlan(context: context, settings: settings.commitMessageAI)
    }

    func executeCollaborationStep() {
        collaborationFeature.execute(settings: settings.commitMessageAI) { [weak self] intent in
            guard let self else { throw CancellationError() }
            try await self.commitCollaboration(intent)
        }
    }

    func undoCollaborationStep() {
        collaborationFeature.undo { [weak self] intent in
            guard let self else { throw CancellationError() }
            try await self.commitCollaboration(intent)
        }
    }

    private func commitCollaboration(_ intent: CollaborationPendingWrite) async throws {
        guard let root = workspaceURL, collaborationFeature.workspaceURL == root,
              collaborationFeature.plan?.id == intent.plan.id else { throw CancellationError() }
        let documents = documentFeature.editorDocuments
        let hold = try await EditorClosingPreparation.acquire(documents)
        defer { hold.release() }
        try Task.checkCancellation()
        guard workspaceURL == root, collaborationFeature.plan?.version == intent.plan.version,
              hold.matches(documentFeature.editorDocuments), !documents.contains(where: \.isDirty),
              agentConversationFeatureIfActive?.hasRespondingConversation != true else { throw AgentEditRestoreError.dirtyBuffer }
        try services.collaborationWorkspace.apply(intent, workspace: root)
        documentFeature.processExternalChanges(intent.receipt.after.map { root.appendingPathComponent($0.path) })
    }

    func rollbackCollaborationWrite() {
        collaborationFeature.rollbackPending { [weak self] in
            guard let self, let root = self.workspaceURL else { throw CancellationError() }
            let documents = self.documentFeature.editorDocuments
            let hold = try await EditorClosingPreparation.acquire(documents)
            defer { hold.release() }
            try Task.checkCancellation()
            guard self.workspaceURL == root, hold.matches(self.documentFeature.editorDocuments),
                  !documents.contains(where: \.isDirty) else { throw AgentEditRestoreError.dirtyBuffer }
            let pending = try self.services.collaborationWorkspace.pending(workspace: root)
            try self.services.collaborationWorkspace.rollback(workspace: root)
            self.documentFeature.processExternalChanges((pending?.receipt.before ?? []).map { root.appendingPathComponent($0.path) })
        }
    }

}
