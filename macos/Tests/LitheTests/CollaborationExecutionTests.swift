import Foundation
import Testing
import LitheCoreContracts
import LitheExecutionModule
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

    @MainActor @Test(.timeLimit(.minutes(1)))
    func nativeModelAppliesOnlyPreparedChangesAndPersistsReceiptBeforeClearingJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: workspace.appendingPathComponent("Order.java"))
        let storage = CollaborationDiskStorage(root: root.appendingPathComponent("state"))
        let adapter = MacCollaborationWorkspace(files: storage, documents: MacWorkspaceFileOperations())
        let changes = [CollaborationChange(target: target, expectedText: "{ return \"old\"; }", replacement: "{ return \"new\"; }")]
        struct Response: Encodable { let changes: [CollaborationChange] }
        let response = String(decoding: try JSONEncoder().encode(Response(changes: changes)), as: UTF8.self)
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: CollaborationExecutionStore(), files: storage, generator: FixedCollaborationModel(response: response), editing: adapter)
        feature.bind(workspace: workspace)
        let package = CollaborationWorkflow(schemaVersion: 1, id: "execution", version: "1.0.0", title: "mapping",
            requirement: "mapping", steps: plan().steps, prompts: [:])
        feature.importWorkflow(data: try JSONEncoder().encode(package))
        feature.perform("confirm"); feature.perform("start")
        let operation = feature.execute(settings: .default) { intent in try adapter.apply(intent, workspace: workspace) }
        await operation?.value
        #expect(feature.error == nil)
        #expect(feature.plan?.phase == .review)
        #expect(feature.receipts.count == 1)
        #expect(try adapter.pending(workspace: workspace) == nil)
        #expect(try adapter.loadSession(workspace: workspace) != nil)
        let restored = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: CollaborationExecutionStore(), files: storage, editing: adapter)
        restored.bind(workspace: workspace)
        #expect(restored.receipts.count == 1)
        #expect(restored.plan?.paused == true)
        let undo = restored.undo { intent in try adapter.apply(intent, workspace: workspace) }
        await undo?.value
        #expect(restored.error == nil)
        #expect(restored.receipts.isEmpty)
        #expect(try String(contentsOf: workspace.appendingPathComponent("Order.java"), encoding: .utf8) == source)
    }

    @Test func nullFileIdentitySurvivesTheSwiftCoreBoundary() throws {
        let file = CollaborationFile(path: "new.java", text: nil)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        #expect(value["text"] is NSNull)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func piToolWritesHaveSeparateReceiptsAndUndoOneEditAtATime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: workspace.appendingPathComponent("Order.java"))
        let storage = CollaborationDiskStorage(root: root.appendingPathComponent("state"))
        let adapter = MacCollaborationWorkspace(files: storage, documents: MacWorkspaceFileOperations())
        let runner = ScriptedPiEdits(changes: [
            .init(target: target, expectedText: "{ return \"old\"; }", replacement: "{ return \"first\"; }"),
            .init(target: target, expectedText: "{ return \"first\"; }", replacement: "{ return \"second\"; }")
        ])
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: CollaborationExecutionStore(), files: storage, editing: adapter, pi: runner)
        feature.bind(workspace: workspace)
        let package = CollaborationWorkflow(schemaVersion: 1, id: "pi", version: "1", title: "map", requirement: "map", steps: plan().steps, prompts: [:])
        feature.importWorkflow(data: try JSONEncoder().encode(package))
        feature.perform("confirm"); feature.perform("start")
        var settings = CommitMessageAISettings.default
        let provider = AIProviderProfile(name: "fixture", endpoint: "https://example.test/v1", model: "fixture", apiProtocol: .chatCompletions)
        settings.providers = [provider]; settings.activeProviderID = provider.id
        let operation = feature.executePi(settings: settings, projectPaths: ["Order.java"], prepareRead: {}) { intent in
            #expect(intent.continuesStep == true)
            try adapter.apply(intent, workspace: workspace)
        }
        await operation?.value
        #expect(feature.error == nil)
        #expect(feature.plan?.phase == .review)
        #expect(feature.receipts.count == 2)
        #expect(Set(feature.receipts.map(\.key)).count == 2)
        #expect(try adapter.pending(workspace: workspace) == nil)
        feature.perform("pause")
        await feature.undo { try adapter.apply($0, workspace: workspace) }?.value
        #expect(feature.error == nil)
        #expect(feature.receipts.count == 1)
        #expect(try String(contentsOf: workspace.appendingPathComponent("Order.java"), encoding: .utf8).contains("return \"first\";"))
        await feature.undo { try adapter.apply($0, workspace: workspace) }?.value
        #expect(feature.error == nil)
        #expect(feature.receipts.isEmpty)
        #expect(try String(contentsOf: workspace.appendingPathComponent("Order.java"), encoding: .utf8) == source)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func takeoverDuringCommitReconcilesTheWriteButPreventsTheNextTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: workspace.appendingPathComponent("Order.java"))
        let storage = CollaborationDiskStorage(root: root.appendingPathComponent("state"))
        let adapter = MacCollaborationWorkspace(files: storage, documents: MacWorkspaceFileOperations())
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: CollaborationExecutionStore(), files: storage, editing: adapter,
            pi: ScriptedPiEdits(changes: [
                .init(target: target, expectedText: "{ return \"old\"; }", replacement: "{ return \"first\"; }"),
                .init(target: target, expectedText: "{ return \"first\"; }", replacement: "{ return \"second\"; }")
            ]))
        feature.bind(workspace: workspace)
        let package = CollaborationWorkflow(schemaVersion: 1, id: "pi", version: "1", title: "map", requirement: "map", steps: plan().steps, prompts: [:])
        feature.importWorkflow(data: try JSONEncoder().encode(package))
        feature.perform("confirm"); feature.perform("start")
        var settings = CommitMessageAISettings.default
        let provider = AIProviderProfile(name: "fixture", endpoint: "https://example.test/v1", model: "fixture", apiProtocol: .chatCompletions)
        settings.providers = [provider]; settings.activeProviderID = provider.id
        let operation = feature.executePi(settings: settings, projectPaths: ["Order.java"], prepareRead: {}) { intent in
            try adapter.apply(intent, workspace: workspace)
            feature.takeOver()
        }
        await operation?.value
        await feature.shutdown()
        #expect(feature.receipts.count == 1)
        #expect(feature.plan?.paused == true)
        #expect(try adapter.pending(workspace: workspace) == nil)
        #expect(try String(contentsOf: workspace.appendingPathComponent("Order.java"), encoding: .utf8).contains("return \"first\";"))
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func parallelPiTasksKeepSeparateGrantsAndSerializeJournalCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let storage = CollaborationDiskStorage(root: root.appendingPathComponent("state"))
        let adapter = MacCollaborationWorkspace(files: storage, documents: MacWorkspaceFileOperations())
        let runner = ParallelToolPi()
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: CollaborationExecutionStore(), files: storage, editing: adapter, pi: runner)
        feature.bind(workspace: workspace)
        let steps = (0..<2).map { index in
            CollaborationStep(id: "task-\(index)", title: "Map \(index)", owner: .ai,
                targets: [.init(kind: "file", path: "Map\(index).java")], acceptance: ["Review mapping"], questions: [])
        }
        let package = CollaborationWorkflow(schemaVersion: 2, id: "parallel", version: "1", title: "Parallel maps", requirement: "maps",
            steps: steps, prompts: [:], dependsOn: ["task-0": [], "task-1": []])
        feature.importWorkflow(data: try JSONEncoder().encode(package))
        #expect(feature.plan?.steps.count == 1)
        feature.perform("confirm"); feature.perform("start")
        var settings = CommitMessageAISettings.default
        let provider = AIProviderProfile(name: "fixture", endpoint: "https://example.test/v1", model: "fixture", apiProtocol: .chatCompletions)
        settings.providers = [provider]; settings.activeProviderID = provider.id
        let firstCommit = TestGate(), release = TestGate()
        var commits = 0
        let operation = feature.executePi(settings: settings, projectPaths: [], prepareRead: {}) { intent in
            #expect(try adapter.pending(workspace: workspace) == nil)
            commits += 1
            if commits == 1 {
                firstCommit.open()
                guard await release.waitUntilOpen() else { throw PiAgentFailure.timedOut }
            }
            try adapter.apply(intent, workspace: workspace)
        }
        defer { release.open(); operation?.cancel() }
        #expect(await firstCommit.waitUntilOpen())
        #expect(await runner.bothWriting.waitUntilOpen())
        #expect(commits == 1, "Second model cannot enter a pending journal commit")
        release.open()
        await operation?.value
        #expect(feature.error == nil)
        #expect(feature.plan?.phase == .review)
        #expect(commits == 2)
        #expect(feature.receipts.count == 2)
        #expect(Set(feature.receipts.map(\.key)).count == 2, "Identical tool IDs in separate sessions must remain distinct")
        #expect(await runner.scopeRejections == 2)
        #expect(try adapter.pending(workspace: workspace) == nil)
        #expect(try String(contentsOf: workspace.appendingPathComponent("Map0.java"), encoding: .utf8) == "map-0")
        #expect(try String(contentsOf: workspace.appendingPathComponent("Map1.java"), encoding: .utf8) == "map-1")
        await feature.shutdown()
    }

    @Test func humanStartCreatesOnlyAnEmptyFileAndPreservesExistingCode() throws {
        try fixture { root, adapter in
            try adapter.prepareHumanFile(path: "Core.java", workspace: root)
            #expect(try String(contentsOf: root.appendingPathComponent("Core.java"), encoding: .utf8).isEmpty)
            try Data("human implementation".utf8).write(to: root.appendingPathComponent("Core.java"))
            try adapter.prepareHumanFile(path: "Core.java", workspace: root)
            #expect(try String(contentsOf: root.appendingPathComponent("Core.java"), encoding: .utf8) == "human implementation")
            #expect(throws: AgentEditRestoreError.self) { try adapter.prepareHumanFile(path: "../outside.java", workspace: root) }
            #expect(try adapter.pending(workspace: root) == nil, "Human creation is not an AI modification receipt")
        }
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func isolatedVerificationReusesTestServiceAndCannotModifyOriginalSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let original = workspace.appendingPathComponent("Order.java")
        try Data(source.utf8).write(to: original)
        try Data("<project><modelVersion>4.0.0</modelVersion></project>".utf8).write(to: workspace.appendingPathComponent("pom.xml"))
        let script = root.appendingPathComponent("fixture-maven")
        let quoted = "'" + original.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = """
        #!/bin/sh
        if printf 'overwritten' > \(quoted); then exit 21; fi
        mkdir -p target
        printf 'snapshot test ran' > target/fixture-result
        printf 'fixture checks completed'
        """
        try Data(command.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let storage = CollaborationDiskStorage(root: root.appendingPathComponent("state with spaces"))
        let resolver = CollaborationFixtureExecutable(url: script)
        let verifier = MacCollaborationVerifier(files: storage) { process in
            LanguageTestService(executableResolver: resolver, processFactory: { process })
        }
        let result = try await verifier.verify(workspace: workspace, actionID: "java-tests")
        #expect(result.outcome == "passed")
        #expect(result.exitCode == 0)
        #expect(result.output.contains("fixture checks completed"))
        #expect(result.sourceRevision.count == 64)
        #expect(try String(contentsOf: original, encoding: .utf8) == source)
        let sessions = storage.cacheDirectory().appendingPathComponent("Lithe/Pi/Validation")
        #expect(storage.listDirectory(at: sessions).isEmpty)
    }
}

@MainActor private final class CollaborationFixtureExecutable: RunExecutableResolving {
    let url: URL
    init(url: URL) { self.url = url }
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable {
        .init(executableURL: url, environment: ["PATH": "/usr/bin:/bin"])
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

private struct FixedCollaborationModel: CollaborationGenerating {
    let response: String
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String { response }
}

private struct ScriptedPiEdits: PiAgentRunning {
    let changes: [CollaborationChange]
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        for (index, change) in changes.enumerated() {
            try Task.checkCancellation()
            _ = try await tool(PiToolRequest(runId: request.runID, toolCallId: "call-\(index)", name: "workspace_apply",
                arguments: PiToolArguments(changes: [change])))
        }
        return "已完成两次有记录的修改，测试尚未执行。"
    }
}
private final class CollaborationExecutionStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private actor ParallelToolPi: PiAgentRunning {
    nonisolated let bothWriting = TestGate()
    nonisolated let grantsChecked = TestGate()
    private var writing = 0
    private(set) var scopeRejections = 0
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        // Automatic narration shares the runner port but has no development
        // grant. This fixture models only developer sessions; narration uses
        // the normal unavailable-explanation fallback without touching counters.
        guard request.role == .development else { throw PiAgentFailure.modelFailed }
        let index = request.runID.hasSuffix(".0") ? 0 : 1
        // A sibling's target is in the wave but never in this session's grant.
        do {
            _ = try await tool(.init(runId: request.runID, toolCallId: "denied", name: "workspace_apply",
                arguments: .init(changes: [.init(target: .init(kind: "file", path: "Map\(1 - index).java"), expectedText: nil, replacement: "forbidden")])) )
            Issue.record("Sibling write should be denied")
        } catch PiAgentFailure.toolDenied { scopeRejections += 1 }
        if scopeRejections == 2 { grantsChecked.open() }
        guard await grantsChecked.waitUntilOpen() else { throw PiAgentFailure.timedOut }
        writing += 1
        if writing == 2 { bothWriting.open() }
        _ = try await tool(.init(runId: request.runID, toolCallId: "same-id", name: "workspace_apply",
            arguments: .init(changes: [.init(target: .init(kind: "file", path: "Map\(index).java"), expectedText: nil, replacement: "map-\(index)")])))
        return "已写入；未运行测试。"
    }
}
