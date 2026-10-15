import Foundation
import Testing
import LitheCoreContracts
import LitheAIAssistanceModule
@testable import Lithe

@Suite("Collaboration immersive workflow", .timeLimit(.minutes(1)))
struct CollaborationImmersiveTests {
    private func settings(_ api: CommitMessageAPIProtocol = .responses) -> CommitMessageAISettings {
        let provider = AIProviderProfile(name: "Fixture", endpoint: "https://fixture.test/v1", model: "fixture",
            apiProtocol: api, requiresAPIKey: false)
        var result = CommitMessageAISettings.default
        result.providers = [provider]; result.activeProviderID = provider.id
        return result
    }

    @Test func streamedUnicodeWorksAcrossEveryByteBoundary() async throws {
        let events = [
            #"data: {"type":"response.output_text.delta","delta":"第一行\n"}"#,
            #"data: {"type":"response.output_text.delta","delta":"return \"✓\";"}"#,
            #"data: {"type":"response.completed"}"#
        ].joined(separator: "\r\n\r\n") + "\r\n\r\n"
        let recorded = ImmersiveTextRecorder()
        let transport = ImmersiveStreamTransport(body: events)
        let service = CommitMessageGenerationService(transport: transport, credentialResolver: ImmersiveNoCredentials())
        let result = try await service.generateWorkflowText(system: "fixture", prompt: "fixture", settings: settings(), onText: { recorded.append($0) })
        #expect(result == "第一行\nreturn \"✓\";")
        #expect(recorded.values.last == result)
        #expect(recorded.values.contains("第一行\n"))
        let request = try #require(await transport.request)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(request.timeout == 180)
    }

    @Test func chatAndAnthropicStreamsRequireSuccessfulTermination() async throws {
        let fixtures: [(CommitMessageAPIProtocol, String, Bool)] = [
            (.chatCompletions, "data: {\"choices\":[{\"delta\":{\"content\":\"code\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n", true),
            (.anthropicMessages, "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"code\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n", true),
            (.responses, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"code\"}\n\n", false),
            (.responses, "data: {\"type\":\"response.incomplete\"}\n\ndata: {\"type\":\"response.completed\"}\n\n", false),
            (.chatCompletions, "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n", false)
        ]
        for (api, payload, valid) in fixtures {
            let service = CommitMessageGenerationService(transport: ImmersiveStreamTransport(body: payload), credentialResolver: ImmersiveNoCredentials())
            do {
                let result = try await service.generateWorkflowText(system: "fixture", prompt: "fixture", settings: settings(api), onText: { _ in })
                #expect(valid && result == "code")
            } catch { #expect(!valid) }
        }
    }

    @Test func ordinaryJSONFallbackDoesNotRetryTheRequest() async throws {
        let transport = ImmersiveStreamTransport(body: #"{"output_text":"code"}"#)
        let service = CommitMessageGenerationService(transport: transport, credentialResolver: ImmersiveNoCredentials())
        #expect(try await service.generateWorkflowText(system: "fixture", prompt: "fixture", settings: settings(), onText: { _ in }) == "code")
        #expect(await transport.count == 1)
    }

    @Test func draftPreviewDoesNotConfuseQuotedKeysWithReplacement() {
        #expect(CollaborationDraftText.replacement(in: #"{"changes":[{"expectedText":"\"replacement\":\"wrong\"","replacement":"line\nnext"#) == "line\nnext")
        #expect(CollaborationDraftText.replacement(in: #"{"replacement":"abc\u4"#) == "abc")
        #expect(CollaborationDraftText.replacement(in: #"{"replacement":"abc\"#) == "abc")
        #expect(CollaborationDraftText.replacement(in: #"{"expectedText":"code"}"#) == nil)
    }

    @MainActor @Test func manualEditingAndPinningSuspendAutomaticNavigation() {
        let view = CollaborationPresentationModel()
        let target = CollaborationTarget(kind: "file", path: "Map.java")
        view.begin(groups: [[target]])
        view.requestOpen("Map.java")
        let original = view.navigation
        view.userDidEdit(); view.requestOpen("Other.java")
        #expect(view.navigation == original)
        view.follow(); view.requestOpen("Other.java")
        #expect(view.navigation?.path == "Other.java")
        view.select(view.tasks[0].id)
        #expect(!view.followsActivity)
        view.tasks[0].state = .generating
        view.cancel()
        #expect(view.tasks[0].state == .cancelled)
        view.reset()
        #expect(view.tasks.isEmpty && view.navigation == nil && view.followsActivity)
    }

    @Test func parallelMetadataCannotGrantAdditionalFilesOrHumanWork() throws {
        var workflow = workflow()
        try workflow.validate()
        workflow.independentFiles = ["support": ["Map0.java", "outside.java"]]
        #expect(throws: CollaborationFailure.self) { try workflow.validate() }
        workflow.independentFiles = ["core": ["Map0.java", "Map1.java"]]
        #expect(throws: CollaborationFailure.self) { try workflow.validate() }
    }

    @MainActor @Test func planningDiscoversExistingCodeAndRejectsUnlistedSelections() async throws {
        for path in ["Map0.java", "unlisted.java"] {
            let generator = ImmersiveSelectionGenerator(path: path, workflow: try JSONEncoder().encode(workflow()))
            let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
                store: ImmersiveMemoryStore(), files: UnavailableFileStorage(), generator: generator, editing: ImmersiveDiscoveryWorkspace())
            feature.bind(workspace: URL(fileURLWithPath: "/fixture/project"))
            feature.requirementText = "维护映射"
            await feature.generatePlan(context: "", settings: .default, projectPaths: ["Map0.java", ".env", "secret.key"])?.value
            if path == "Map0.java" {
                #expect(feature.plan?.phase == .draft)
                #expect(await generator.prompts.last?.contains("existingMapping") == true)
            } else {
                #expect(feature.plan == nil && feature.error != nil)
                #expect(await generator.prompts.count == 1)
            }
            #expect(await generator.prompts.first?.contains(".env") == false)
            #expect(await generator.prompts.first?.contains("secret.key") == false)
            await feature.shutdown()
        }
    }

    @Test func workerCannotReturnChangesForAnotherConfirmedGroup() async throws {
        let target = CollaborationTarget(kind: "file", path: "Map0.java")
        do {
            _ = try await CollaborationDraftService(generator: ImmersiveCrossGroupGenerator()).generate(groups: [[target]],
                system: "fixture", prompt: "fixture", context: "[]", settings: .default, onEvent: { _ in })
            Issue.record("Cross-group edit was accepted")
        } catch { #expect(error is CollaborationFailure) }
    }

    @MainActor @Test func dirtyReadBarrierStopsGenerationBeforeAnyRequest() async throws {
        let generator = ImmersiveControlledGenerator()
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: ImmersiveMemoryStore(), files: UnavailableFileStorage(), generator: generator, editing: ImmersiveWorkspace())
        feature.bind(workspace: URL(fileURLWithPath: "/fixture/project"))
        feature.importWorkflow(data: try JSONEncoder().encode(workflow()))
        feature.perform("confirm"); feature.perform("start")
        var writes = 0
        await feature.execute(settings: .default, prepareRead: { throw AgentEditRestoreError.dirtyBuffer }) { _ in writes += 1 }?.value
        #expect(await generator.count == 0)
        #expect(writes == 0 && feature.error != nil)
        #expect(feature.presentation.tasks.allSatisfy { $0.state == .failed })
        await feature.shutdown()
    }

    @Test func parallelGenerationIsBoundedAndResultsKeepConfirmedOrder() async throws {
        let model = ImmersiveControlledGenerator()
        let targets = (0..<5).map { CollaborationTarget(kind: "file", path: "Map\($0).java") }
        let task = Task { try await CollaborationDraftService(generator: model).generate(groups: targets.map { [$0] },
            system: "fixture", prompt: "fixture", context: "[]", settings: .default, onEvent: { _ in }) }
        defer { model.release.open(); task.cancel() }
        #expect(await model.threeStarted.waitUntilOpen(), "The first three workers must reach the gate")
        #expect(await model.count == 3)
        model.release.open()
        let changes = try await task.value
        #expect(changes.map(\.target.path) == targets.map(\.path))
        #expect(await model.peak <= 3)
    }

    @MainActor @Test func takeoverCancelsAndDrainsBeforeLateDraftCanWrite() async throws {
        let generator = ImmersiveControlledGenerator()
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: ImmersiveMemoryStore(), files: UnavailableFileStorage(), generator: generator, editing: ImmersiveWorkspace())
        feature.bind(workspace: URL(fileURLWithPath: "/fixture/project"))
        feature.importWorkflow(data: try JSONEncoder().encode(workflow()))
        feature.perform("confirm"); feature.perform("start")
        var writes = 0
        let operation = try #require(feature.execute(settings: .default) { _ in writes += 1 })
        defer { generator.release.open(); feature.cancel() }
        #expect(await generator.firstStarted.waitUntilOpen())
        feature.takeOver()
        generator.release.open()
        await operation.value
        await feature.shutdown()
        #expect(writes == 0)
        #expect(feature.plan?.paused == true)
        #expect(feature.receipts.isEmpty)
        #expect(feature.presentation.tasks.allSatisfy { $0.state == .cancelled })
        #expect(!feature.busy)
    }

    private func workflow() -> CollaborationWorkflow {
        .init(schemaVersion: 1, id: "parallel", version: "1.0.0", title: "配套", requirement: "映射配套，核心人工",
            steps: [.init(id: "support", title: "映射", owner: .ai,
                targets: [.init(kind: "file", path: "Map0.java"), .init(kind: "file", path: "Map1.java")],
                acceptance: ["独立接口"], questions: [])], prompts: [:], independentFiles: ["support": ["Map0.java", "Map1.java"]])
    }
}

private struct ImmersiveNoCredentials: AIProviderCredentialResolver {
    func readAPIKey(for provider: AIProviderProfile) -> String? { nil }
}
private actor ImmersiveStreamTransport: AIHTTPTransport {
    let body: String
    private(set) var request: AIHTTPRequest?
    private(set) var count = 0
    init(body: String) { self.body = body }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        self.request = request; count += 1
        for byte in body.utf8 { request.onBody?(Data([byte])) }
        return .init(statusCode: 200, body: Data(body.utf8))
    }
}
private final class ImmersiveTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func append(_ text: String) { lock.withLock { recorded.append(text) } }
}
private actor ImmersiveControlledGenerator: CollaborationGenerating {
    nonisolated let firstStarted = TestGate()
    nonisolated let threeStarted = TestGate()
    nonisolated let release = TestGate()
    private(set) var count = 0
    private(set) var peak = 0
    private var active = 0
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        count += 1; active += 1; peak = max(peak, active)
        firstStarted.open()
        if count == 3 { threeStarted.open() }
        _ = await release.waitUntilOpen()
        defer { active -= 1 }
        // Deliberately return even after cancellation to exercise host invalidation.
        let scope = prompt.components(separatedBy: "本请求仅授权这些目标（原样复制，不修改其他文件）：").last?.components(separatedBy: "\n源码快照：").first ?? "[]"
        let targets = try JSONDecoder().decode([CollaborationTarget].self, from: Data(scope.utf8))
        struct Output: Encodable { let changes: [CollaborationChange] }
        return String(decoding: try JSONEncoder().encode(Output(changes: targets.map {
            .init(target: $0, expectedText: nil, replacement: "class Mapping {}")
        })), as: UTF8.self)
    }
}
private struct ImmersiveWorkspace: CollaborationWorkspaceEditing {
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile] { paths.map { .init(path: $0, text: nil) } }
    func pending(workspace: URL) throws -> CollaborationPendingWrite? { nil }
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws {}
    func finish(workspace: URL) throws {}
    func rollback(workspace: URL) throws {}
}
private struct ImmersiveDiscoveryWorkspace: CollaborationWorkspaceEditing {
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile] {
        guard paths == ["Map0.java"] else { throw CollaborationFailure.invalidState }
        return [.init(path: "Map0.java", text: "class Mapping { int existingMapping() { return 1; } }")]
    }
    func pending(workspace: URL) throws -> CollaborationPendingWrite? { nil }
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws {}
    func finish(workspace: URL) throws {}
    func rollback(workspace: URL) throws {}
}
private actor ImmersiveSelectionGenerator: CollaborationGenerating {
    let path: String
    let workflow: Data
    private(set) var prompts: [String] = []
    init(path: String, workflow: Data) { self.path = path; self.workflow = workflow }
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        prompts.append(prompt)
        if prompts.count == 1 { return String(decoding: try JSONEncoder().encode(["paths": [path]]), as: UTF8.self) }
        return String(decoding: workflow, as: UTF8.self)
    }
}
private struct ImmersiveCrossGroupGenerator: CollaborationGenerating {
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        #"{"changes":[{"target":{"kind":"file","path":"Other.java"},"expectedText":null,"replacement":"wrong"}]}"#
    }
}
private final class ImmersiveMemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
