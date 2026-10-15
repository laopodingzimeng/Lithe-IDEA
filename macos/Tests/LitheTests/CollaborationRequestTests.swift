import Foundation
import LitheAIAssistanceModule
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Collaboration request behavior", .timeLimit(.minutes(1)))
struct CollaborationRequestTests {
    private func settings() -> CommitMessageAISettings {
        let provider = AIProviderProfile(name: "Fixture", endpoint: "https://fixture.test/v1",
            model: "fixture-model", apiProtocol: .responses, requiresAPIKey: false)
        var settings = CommitMessageAISettings.default
        settings.providers = [provider]; settings.activeProviderID = provider.id
        settings.reasoningEffort = .xhigh
        return settings
    }

    @Test func planningContextBoundsUnicodeAndMarksIncompleteSources() {
        let files = (0..<10).map { CollaborationFile(path: "File\($0).java", text: String(repeating: "核心", count: 20_000)) }
        let context = CollaborationPlanningContext.render(files)
        #expect(context.count <= 24_000)
        #expect(context.contains("文件：File0.java"))
        #expect(context.contains("代码已截断"))
        #expect(!context.contains("File8.java"))
        let short = CollaborationPlanningContext.render((0..<10).map { .init(path: "File\($0).java", text: "code") })
        #expect(short.contains("File7.java"))
        #expect(!short.contains("File8.java"))
        #expect(!short.contains("截断"))
    }

    @Test func workflowsUseTheirOwnBudgetAndDoNotInheritCommitReasoning() async throws {
        let transport = CollaborationRequestTransport()
        let service = CommitMessageGenerationService(transport: transport, credentialResolver: NoCollaborationCredentials())
        let settings = settings()
        _ = try await service.generateWorkflowText(system: "Plan only", prompt: "fixture requirement", settings: settings)
        try await service.testConnection(provider: try #require(settings.activeProvider))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].timeout == 180)
        #expect(requests[1].timeout == 45, "Short probes retain their existing budget")
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        #expect(body["reasoning"] == nil, "Commit xhigh must not silently configure a workflow model")
        #expect(body["model"] as? String == "fixture-model")
        #expect(body["max_output_tokens"] as? Int == 8192)
    }

    @Test func transportTimeoutBecomesActionableWithoutExposingUpstreamText() async throws {
        let transport = CollaborationRequestTransport(fail: true)
        let service = CollaborationGenerationService(service: .init(transport: transport, credentialResolver: NoCollaborationCredentials()))
        do {
            _ = try await service.generate(system: "fixture", prompt: "fixture", settings: settings())
            Issue.record("Expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("180 秒"))
            #expect(error.localizedDescription.contains("测试连接"))
            #expect(!error.localizedDescription.contains("upstream-secret"))
        }
    }

    @MainActor @Test func failedAnalysisPreservesRequirementAndCanBeRetried() async throws {
        let package = CollaborationWorkflow(schemaVersion: 1, id: "fixture", version: "1.0.0", title: "Fixture",
            requirement: "core", steps: [.init(id: "core", title: "Core", owner: .human,
            targets: [.init(kind: "file", path: "Core.java")], acceptance: ["Review"], questions: [])], prompts: [:])
        let generator = RetryCollaborationGenerator(response: String(decoding: try JSONEncoder().encode(package), as: UTF8.self))
        let feature = CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: RequestMemoryStore(), files: UnavailableFileStorage(), generator: generator)
        defer { feature.cancel() }
        feature.bind(workspace: URL(fileURLWithPath: "/fixture/project"))
        feature.requirementText = "我的核心逻辑由我编写"
        await feature.generatePlan(context: "", settings: settings())?.value
        #expect(!feature.busy)
        #expect(feature.error?.contains("测试连接") == true)
        #expect(feature.requirementText == "我的核心逻辑由我编写")
        #expect(feature.plan == nil)
        await feature.generatePlan(context: "", settings: settings())?.value
        #expect(feature.error == nil)
        #expect(feature.plan?.phase == .draft)
    }
}

private actor CollaborationRequestTransport: AIHTTPTransport {
    private(set) var requests: [AIHTTPRequest] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        if fail { throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "upstream-secret"]) }
        return .init(statusCode: 200, body: Data(#"{"output_text":"OK"}"#.utf8))
    }
}
private struct NoCollaborationCredentials: AIProviderCredentialResolver {
    func readAPIKey(for provider: AIProviderProfile) -> String? { nil }
}
private actor RetryCollaborationGenerator: CollaborationGenerating {
    let response: String
    var attempt = 0
    init(response: String) { self.response = response }
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        attempt += 1
        if attempt == 1 { throw CollaborationRequestFailure.timedOut }
        return response
    }
}
private final class RequestMemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
