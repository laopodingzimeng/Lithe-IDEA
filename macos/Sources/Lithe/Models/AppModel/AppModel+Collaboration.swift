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
        // Absent planned files have a draft preview until the guarded write
        // creates them. Avoid opening an unavailable document as an empty file.
        guard (try? services.collaborationWorkspace.snapshot(paths: [relativePath], workspace: root).first?.text) != nil else { return }
        // Reuse the existing document navigation and workspace access policy.
        openFile(root.appendingPathComponent(relativePath))
    }
    func generateCollaborationPlan() {
        guard let root = workspaceURL else { return }
        collaborationFeature.bind(workspace: root)
        let files = documentFeature.editorDocuments.compactMap { document -> CollaborationFile? in
            let prefix = root.standardizedFileURL.path + "/"
            guard document.url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
            let path = String(document.url.standardizedFileURL.path.dropFirst(prefix.count))
            guard CollaborationPlanningContext.canShare(path) else { return nil }
            return CollaborationFile(path: path, text: document.text)
        }
        let context = collaborationFeature.includeEditorContext ? CollaborationPlanningContext.render(files) : "（本次仅分析需求，未附带代码）"
        let prefix = root.standardizedFileURL.path + "/"
        let paths = collaborationFeature.includeEditorContext ? projectFiles.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        } : []
        collaborationFeature.generatePlan(context: context, settings: settings.commitMessageAI, projectPaths: paths)
    }

    func startCollaborationStep() {
        collaborationFeature.perform("start")
        if collaborationFeature.plan?.phase == .aiWorking { executeCollaborationStep() }
    }

    func handoffCollaborationStep() {
        collaborationFeature.perform("handoff")
        if collaborationFeature.plan?.phase == .checking { executeCollaborationStep() }
    }

    func executeCollaborationStep() {
        collaborationFeature.execute(settings: settings.commitMessageAI, prepareRead: { [weak self] in
            guard let self, let root = self.workspaceURL, let plan = self.collaborationFeature.plan else { throw CancellationError() }
            let paths = Set(plan.steps.flatMap { $0.targets.map(\.path) })
            let documents = self.collaborationDocuments(paths: paths, root: root)
            let hold = try await EditorClosingPreparation.acquire(documents)
            defer { hold.release() }
            guard self.workspaceURL == root, self.collaborationFeature.plan?.version == plan.version,
                  hold.matches(self.collaborationDocuments(paths: paths, root: root)), !documents.contains(where: \.isDirty) else {
                throw AgentEditRestoreError.dirtyBuffer
            }
        }) { [weak self] intent in
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
        let paths = Set(intent.receipt.before.map(\.path))
        let documents = collaborationDocuments(paths: paths, root: root)
        let hold = try await EditorClosingPreparation.acquire(documents)
        defer { hold.release() }
        try Task.checkCancellation()
        guard workspaceURL == root, collaborationFeature.plan?.version == intent.plan.version,
              hold.matches(collaborationDocuments(paths: paths, root: root)), !documents.contains(where: \.isDirty),
              agentConversationFeatureIfActive?.hasRespondingConversation != true else { throw AgentEditRestoreError.dirtyBuffer }
        try services.collaborationWorkspace.apply(intent, workspace: root)
        documentFeature.processExternalChanges(intent.receipt.after.map { root.appendingPathComponent($0.path) })
    }

    private func collaborationDocuments(paths: Set<String>, root: URL) -> [EditorDocument] {
        let urls = Set(paths.map { root.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() })
        return documentFeature.editorDocuments.filter { urls.contains($0.url.standardizedFileURL.resolvingSymlinksInPath()) }
    }

    func followCollaborationTarget(_ path: String) async {
        guard collaborationFeature.presentation.followsActivity, let root = workspaceURL,
              CollaborationWorkflow.isRelativePath(path) else { return }
        if focusedEditorDocument?.isDirty == true {
            collaborationFeature.presentation.userDidEdit()
            return
        }
        let navigation = collaborationFeature.presentation.navigation
        guard (try? services.collaborationWorkspace.snapshot(paths: [path], workspace: root).first?.text) != nil,
              let document = await documentFeature.previewDocument(at: root.appendingPathComponent(path)),
              !Task.isCancelled, workspaceURL == root, collaborationFeature.presentation.followsActivity,
              collaborationFeature.presentation.navigation == navigation, focusedEditorDocument?.isDirty != true else { return }
        documentFeature.promotePreviewDocument(document)
        openFile(document.url)
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
