import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Collaboration model capabilities", .timeLimit(.minutes(1)))
struct CollaborationModelDiagnosticsTests {
    private var provider: AIProviderProfile {
        .init(name: "fixture", endpoint: "https://fixture.test/v1", model: "fixture", apiProtocol: .responses)
    }
    @Test func developmentCapabilityRequiresObservedReadAndScopedWrite() async throws {
        let runner = DiagnosticPiFixture()
        try await CollaborationPiDiagnostics(runner: runner).test(provider: provider, role: .development,
            workspace: URL(fileURLWithPath: "/fixture/project"))
        #expect(await runner.completedProbe)
    }
    @Test func aTextOnlyModelCannotPassTheDevelopmentToolProbe() async {
        do {
            try await CollaborationPiDiagnostics(runner: DiagnosticPiFixture(textOnly: true)).test(provider: provider,
                role: .development, workspace: URL(fileURLWithPath: "/fixture/project"))
            Issue.record("Text alone must not pass the tool capability test")
        } catch { #expect(error is PiAgentFailure) }
    }
    @Test func olderRoleSettingsKeepBindingsWhenNewBudgetsAreAdded() throws {
        let data = Data(#"{"developmentModel":"my-code","presentationModel":"my-explain","maximumParallelTasks":2}"#.utf8)
        let settings = try JSONDecoder().decode(CollaborationModelSettings.self, from: data)
        #expect(settings.developmentModel == "my-code")
        #expect(settings.presentationModel == "my-explain")
        #expect(settings.maximumParallelTasks == 2)
        #expect(settings.developmentOutputTokens == 8192)
        #expect(settings.automaticNarrationRequests == 8)
        #expect(try JSONDecoder().decode(CollaborationModelSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @MainActor @Test func changingProviderCancelsAndDrainsTheOldCapabilityTest() async {
        let runner = DiagnosticPiFixture(controlled: true)
        let model = CollaborationPiDiagnosticsModel(pi: runner)
        model.bind(provider)
        let pending = model.test(role: .development, workspace: URL(fileURLWithPath: "/fixture/project"))
        defer { runner.release.open(); pending?.cancel() }
        #expect(await runner.started.waitUntilOpen())
        var replacement = provider
        replacement.model = "replacement"
        model.bind(replacement)
        runner.release.open()
        await pending?.value
        await model.shutdown()
        #expect(model.state == .idle)
        #expect(model.message == nil, "An old model's result cannot certify the replacement model")
        #expect(await runner.completedProbe == false)
    }
}

private actor DiagnosticPiFixture: PiAgentRunning {
    nonisolated let started = TestGate()
    nonisolated let release = TestGate()
    let textOnly: Bool
    let controlled: Bool
    private(set) var completedProbe = false
    init(textOnly: Bool = false, controlled: Bool = false) { self.textOnly = textOnly; self.controlled = controlled }
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        started.open()
        if controlled {
            guard await release.waitUntilOpen() else { throw PiAgentFailure.timedOut }
            try Task.checkCancellation()
        }
        if textOnly { return #"{"ok":true,"nonce":"invented"}"# }
        let target = CollaborationTarget(kind: "file", path: "capability.txt")
        let data = try await tool(.init(runId: request.runID, toolCallId: "read", name: "workspace_read", arguments: .init(target: target)))
        struct Read: Decodable { let file: CollaborationFile }
        let nonce = try #require(JSONDecoder().decode(Read.self, from: data).file.text)
        _ = try await tool(.init(runId: request.runID, toolCallId: "write", name: "workspace_apply", arguments: .init(changes: [
            .init(target: target, expectedText: nonce, replacement: nonce + "-ok")
        ])))
        completedProbe = true
        return "{\"ok\":true,\"nonce\":\"\(nonce)\"}"
    }
}
