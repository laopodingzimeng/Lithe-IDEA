import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Collaboration human suggestions", .timeLimit(.minutes(1)))
@MainActor
struct CollaborationCompletionTests {
    private let target = CollaborationTarget(kind: "file", path: "Core.java")
    private let source = "class Core { int result() { return 1; } }\r\n"
    private let replacement = "class Core { int result() { return 2; } }\r\n"
    private let workspace = URL(fileURLWithPath: "/fixture/project")
    private var plan: CollaborationPlan {
        .init(id: "human", version: 3, requirement: "Core result", steps: [
            .init(id: "core", title: "Write core", owner: .human, targets: [target], acceptance: ["Correct result"], questions: [])
        ], currentStep: 0, phase: .humanWorking, paused: false)
    }
    private func fixture(controlled: Bool = false) throws -> (CollaborationCompletionModel, EditorDocument, SuggestionPiFixture) {
        let change = CollaborationChange(target: target, expectedText: source, replacement: replacement)
        let runner = SuggestionPiFixture(response: String(decoding: try JSONEncoder().encode(change), as: UTF8.self), controlled: controlled)
        let model = CollaborationCompletionModel(pi: runner, operations: RustCollaborationPlanOperations(core: RustCoreBridge()))
        model.instruction = "Return two"
        let document = EditorDocument(url: workspace.appendingPathComponent(target.path), text: source, modificationDate: nil)
        return (model, document, runner)
    }
    private func request(_ model: CollaborationCompletionModel, _ document: EditorDocument,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        model.request(document: document, workspace: workspace, plan: plan, target: target,
            provider: .init(name: "fixture", endpoint: "https://fixture.test/v1", model: "code", apiProtocol: .responses),
            maximumOutputTokens: 2048, tokenBudget: 8000, isCurrent: isCurrent)
    }

    @Test func generationAndRejectionLeaveTheCoreBufferUntouched() async throws {
        let (model, document, runner) = try fixture()
        await request(model, document)?.value
        #expect(model.state == .ready)
        #expect(model.suggestion?.after == replacement)
        #expect(document.text == source)
        #expect(!document.isDirty)
        #expect(await runner.toolWasDenied)
        model.reject()
        #expect(model.suggestion == nil)
        #expect(document.text == source)
        await model.shutdown()
    }

    @Test func explicitAcceptanceUsesTheEditorWithoutSavingOrHandingOff() async throws {
        let (model, document, _) = try fixture()
        var accepted = 0
        document.acceptSuggestedText = { expected, replacement, completion in
            #expect(document.text == expected)
            accepted += 1
            document.applyLiveEditorText(replacement)
            completion(.success(()))
        }
        defer { document.acceptSuggestedText = nil }
        await request(model, document)?.value
        #expect(accepted == 0)
        await model.accept()?.value
        #expect(accepted == 1)
        #expect(document.text == replacement)
        #expect(document.savedText == source)
        #expect(document.isDirty)
        #expect(model.state == .accepted)
        #expect(model.suggestion == nil)
        await model.shutdown()
    }

    @Test func typingAfterGenerationInvalidatesAcceptanceEvenIfTextIsRestored() async throws {
        let (model, document, _) = try fixture()
        var accepted = false
        document.acceptSuggestedText = { _, _, completion in accepted = true; completion(.success(())) }
        defer { document.acceptSuggestedText = nil }
        await request(model, document)?.value
        document.applyLiveEditorText(source + "// mine")
        document.applyLiveEditorText(source)
        await model.accept()?.value
        #expect(!accepted)
        #expect(model.state == .failed)
        #expect(document.text == source)
        await model.shutdown()
    }

    @Test func lateResultCannotReplaceNewTypingOrAChangedPlan() async throws {
        let (model, document, runner) = try fixture(controlled: true)
        var current = true
        let pending = request(model, document, isCurrent: { current })
        defer { runner.release.open(); pending?.cancel() }
        #expect(await runner.started.waitUntilOpen())
        document.applyLiveEditorText(source + "// human progress")
        current = false
        runner.release.open()
        await pending?.value
        #expect(model.suggestion == nil)
        #expect(model.state == .failed)
        #expect(document.text == source + "// human progress")
        await model.shutdown()
    }
}

private actor SuggestionPiFixture: PiAgentRunning {
    let response: String
    let controlled: Bool
    nonisolated let started = TestGate()
    nonisolated let release = TestGate()
    private(set) var toolWasDenied = false
    init(response: String, controlled: Bool) { self.response = response; self.controlled = controlled }
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        #expect(request.role == .completion)
        do {
            _ = try await tool(.init(runId: request.runID, toolCallId: "forbidden", name: "workspace_apply", arguments: .init()))
            Issue.record("Completion must never have workspace tools")
        } catch PiAgentFailure.toolDenied { toolWasDenied = true }
        started.open()
        if controlled {
            guard await release.waitUntilOpen() else { throw PiAgentFailure.timedOut }
            try Task.checkCancellation()
        }
        return response
    }
}
