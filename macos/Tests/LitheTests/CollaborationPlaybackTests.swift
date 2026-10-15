import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Collaboration independent playback")
struct CollaborationPlaybackTests {
    private func receipt(_ id: String, text: String) -> CollaborationReceipt {
        .init(planId: "plan", planVersion: 3, stepId: "map", before: [.init(path: "Map.java", text: "before")],
              after: [.init(path: "Map.java", text: text)], changes: [], operationId: id)
    }
    private func fact(_ index: UInt64, receipt: CollaborationReceipt) -> CollaborationFact {
        .init(id: "event-\(index)", workspaceID: "workspace", planVersion: 3, runID: "run", taskID: "map",
              sourceSequence: index, recordedAt: nil, kind: "write", title: "已写入映射", receiptID: receipt.key)
    }
    private var provider: AIProviderProfile {
        .init(name: "presentation", endpoint: "https://presentation.example.test/v1", model: "explain", apiProtocol: .chatCompletions)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func stalledNarrationDoesNotBlockDevelopmentAndReplayKeepsItsVersion() async throws {
        let runner = PlaybackControlledPi()
        let playback = CollaborationPlaybackModel(pi: runner)
        let workspace = URL(fileURLWithPath: "/fixture/project")
        let first = receipt("first", text: "historical version")
        let second = receipt("second", text: "latest version")
        playback.configure(workspace: workspace, provider: provider)
        playback.synchronize(facts: [fact(1, receipt: first)], receipts: [first])
        defer { runner.release.open() }
        #expect(await runner.started.waitUntilOpen())
        playback.select("event-1")
        let narration = playback.explainSelected()
        playback.synchronize(facts: [fact(1, receipt: first), fact(2, receipt: second)], receipts: [first, second])
        let development = try await runner.run(.init(runID: "development", role: .development, workspace: workspace,
            provider: provider, system: "fixture", prompt: "continue development"), onEvent: { _ in }, tool: { _ in Data() })
        #expect(development == "development continued")
        #expect(playback.chapters.count == 2)
        #expect(playback.selectedID == "event-1")
        #expect(playback.selectedReceipt?.after.first?.text == "historical version")
        #expect(playback.viewedCount == 0, "Preparing or selecting a chapter is not an acknowledgement of viewing it")
        playback.markViewed("event-1")
        runner.release.open()
        await narration?.value
        #expect(playback.selected?.narration?.sourceEventIDs == ["event-1"])
        #expect(playback.selectedID == "event-1", "Late narration cannot move the playback cursor")
        #expect(playback.viewedCount == 1)
        await playback.shutdown()
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func invalidNarrationKeepsTheHostChapterAndCannotChangeSnapshots() async throws {
        let runner = PlaybackControlledPi(invalid: true)
        runner.release.open()
        let playback = CollaborationPlaybackModel(pi: runner)
        let record = receipt("first", text: "one line")
        playback.configure(workspace: URL(fileURLWithPath: "/fixture/project"), provider: provider, automaticEnabled: false)
        playback.synchronize(facts: [fact(1, receipt: record)], receipts: [record])
        await playback.explainSelected()?.value
        #expect(playback.selected?.narration == nil)
        #expect(playback.explanationError != nil)
        #expect(playback.selectedReceipt?.after.first?.text == "one line")
        #expect(playback.chapters.count == 1)
        await playback.shutdown()
    }

    @Test func modelRolesKeepIndependentSuppliersAndDoNotSilentlyReplaceDeletedBindings() {
        var settings = CommitMessageAISettings.default
        let a = AIProviderProfile(name: "A", endpoint: "https://a.example.test/v1", model: "code", apiProtocol: .responses)
        let b = AIProviderProfile(name: "B", endpoint: "https://b.example.test/v1", model: "explain", apiProtocol: .anthropicMessages)
        settings.providers = [a, b]; settings.activeProviderID = a.id
        var roles = CollaborationModelSettings(developmentProviderID: a.id, developmentModel: "code-large",
            presentationProviderID: b.id, presentationModel: "explain-small")
        #expect(roles.provider(for: .development, in: settings)?.endpoint == a.endpoint)
        #expect(roles.provider(for: .presentation, in: settings)?.endpoint == b.endpoint)
        #expect(roles.provider(for: .presentation, in: settings)?.model == "explain-small")
        #expect(settings.activeProvider?.model == "code")
        roles.presentationProviderID = UUID()
        #expect(roles.provider(for: .presentation, in: settings) == nil)
    }
}

private actor PlaybackControlledPi: PiAgentRunning {
    nonisolated let started = TestGate()
    nonisolated let release = TestGate()
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        if request.role == .development { return "development continued" }
        started.open()
        guard await release.waitUntilOpen() else { throw PiAgentFailure.timedOut }
        let input = try #require(JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any])
        let ids = try #require(input["sourceEventIDs"] as? [String])
        let snapshot = input["snapshotID"] as? String
        let value = CollaborationNarration(schemaVersion: 1, sourceEventIDs: invalid ? ["invented-event"] : ids,
            snapshotID: snapshot, title: "解释映射修改", explanation: "只解释提供的版本。", actions: [])
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
