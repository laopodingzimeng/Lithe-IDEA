import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

/// Native integration tests use only temporary files and a deterministic model response.
@Suite("Collaboration execution")
struct CollaborationExecutionTests {
    private let source = "class Order { int core() { return 1; } String map() { return \"old\"; } }"
    private var target: CollaborationTarget { .init(kind: "javaMethod", path: "Order.java", typeName: "Order", signature: "String map()") }
    private func plan() -> CollaborationPlan {
        .init(id: "test-plan", version: 3, requirement: "mapping", steps: [
            .init(id: "map", title: "map", owner: .ai, targets: [target], acceptance: ["preserve core"], questions: []),
            .init(id: "core", title: "core", owner: .human,
                  targets: [.init(kind: "javaMethod", path: "Order.java", typeName: "Order", signature: "int core()")],
                  acceptance: ["calculate"], questions: [])
        ], currentStep: 0, phase: .aiWorking, paused: false)
    }
    private func fixture(_ body: (URL, MacCollaborationWorkspace) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: workspace.appendingPathComponent("Order.java"))
        let adapter = MacCollaborationWorkspace(files: CollaborationDiskStorage(root: root.appendingPathComponent("state")), documents: MacWorkspaceFileOperations())
        try body(workspace, adapter)
    }
    private func receipt(_ workspace: URL, _ adapter: MacCollaborationWorkspace) throws -> CollaborationReceipt {
        try RustCollaborationPlanOperations(core: RustCoreBridge()).prepare(plan(),
            files: adapter.snapshot(paths: ["Order.java"], workspace: workspace),
            changes: [.init(target: target, expectedText: "{ return \"old\"; }", replacement: "{ return \"new\"; }")])
    }

    @Test func guardedApplyAndMethodUndoPreserveLaterHumanCode() throws {
        try fixture { root, adapter in
            let prepared = try receipt(root, adapter)
            try adapter.apply(.init(receipt: prepared, plan: plan(), undo: false), workspace: root)
            #expect(try adapter.pending(workspace: root)?.receipt.key == prepared.key)
            try adapter.finish(workspace: root)
            let file = root.appendingPathComponent("Order.java")
            let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "return 1;", with: "return 42;")
            try Data(edited.utf8).write(to: file)
            let inverse = try RustCollaborationPlanOperations(core: RustCoreBridge()).reverse(prepared,
                files: adapter.snapshot(paths: ["Order.java"], workspace: root))
            try adapter.apply(.init(receipt: inverse, plan: plan(), undo: true), workspace: root)
            let result = try String(contentsOf: file, encoding: .utf8)
            #expect(result.contains("return 42;"))
            #expect(result.contains("return \"old\";"))
            try adapter.finish(workspace: root)
        }
    }

    @Test func recoveryKeepsJournalUntilExplicitRollbackAndRejectsExternalChanges() throws {
        try fixture { root, adapter in
            let prepared = try receipt(root, adapter)
            try adapter.apply(.init(receipt: prepared, plan: plan(), undo: false), workspace: root)
            let file = root.appendingPathComponent("Order.java")
            let bytes = try Data(contentsOf: file)
            try Data("human changed it".utf8).write(to: file)
            #expect(throws: AgentEditRestoreError.self) { try adapter.rollback(workspace: root) }
            #expect(try adapter.pending(workspace: root) != nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == "human changed it")
            try bytes.write(to: file)
            try adapter.rollback(workspace: root)
            #expect(try String(contentsOf: file, encoding: .utf8) == source)
            #expect(try adapter.pending(workspace: root) == nil)
        }
    }

    @Test func staleBaselineAndSymlinkNeverWrite() throws {
        try fixture { root, adapter in
            let prepared = try receipt(root, adapter)
            let file = root.appendingPathComponent("Order.java")
            try Data("human".utf8).write(to: file)
            #expect(throws: AgentEditRestoreError.self) { try adapter.apply(.init(receipt: prepared, plan: plan(), undo: false), workspace: root) }
            #expect(try adapter.pending(workspace: root) == nil)
            let link = root.appendingPathComponent("Link.java")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: AgentEditRestoreError.self) { try adapter.snapshot(paths: ["Link.java"], workspace: root) }
        }
    }

    @Test func nullFileIdentitySurvivesTheSwiftCoreBoundary() throws {
        let file = CollaborationFile(path: "new.java", text: nil)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        #expect(value["text"] is NSNull)
    }
}

private struct CollaborationDiskStorage: FileStorage {
    let root: URL
    private let delegate = MacFileStorage()
    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? { delegate.metadata(for: url) }
    func fileExists(at url: URL) -> Bool { delegate.fileExists(at: url) }
    func isExecutable(at url: URL) -> Bool { delegate.isExecutable(at: url) }
    func listDirectory(at url: URL) -> [URL] { delegate.listDirectory(at: url) }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { try delegate.readPrefix(from: url, byteCount: byteCount) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { try delegate.readData(from: url, options: options) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try delegate.writeData(data, to: url, options: options) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try delegate.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func removeItem(at url: URL) throws { try delegate.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try delegate.moveItem(at: sourceURL, to: destinationURL) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try delegate.copyItem(at: sourceURL, to: destinationURL) }
}
