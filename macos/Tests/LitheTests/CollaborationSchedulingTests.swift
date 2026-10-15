import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Collaboration Pi scheduling", .timeLimit(.minutes(1)))
struct CollaborationSchedulingTests {
    private func requests(_ count: Int) -> [PiAgentRequest] {
        (0..<count).map { index in
            PiAgentRequest(runID: String(index), role: .development, workspace: URL(fileURLWithPath: "/fixture/project"),
                provider: .init(name: "fixture", endpoint: "https://fixture.test/v1", model: "fixture", apiProtocol: .responses),
                system: "fixture", prompt: String(index))
        }
    }

    @Test func boundedParallelSessionsReturnInTaskOrder() async throws {
        let runner = SchedulingControlledPi()
        let operation = Task {
            try await CollaborationPiExecution(runner: runner).run(requests(4), parallelism: 2,
                event: { _, _ in }, tool: { _, _ in Data() })
        }
        defer { runner.release.open(); operation.cancel() }
        #expect(await runner.twoStarted.waitUntilOpen())
        #expect(await runner.active == 2)
        #expect(await runner.started.sorted() == ["0", "1"])
        runner.release.open()
        let result = try await operation.value
        #expect(result == ["0", "1", "2", "3"])
        #expect(await runner.maximumActive == 2)
        #expect(await runner.active == 0)
    }

    @Test func failedChildCancelsAndDrainsSiblingBeforeReturning() async {
        let runner = SchedulingControlledPi(failFirst: true)
        defer { runner.release.open() }
        do {
            _ = try await CollaborationPiExecution(runner: runner).run(requests(4), parallelism: 2,
                event: { _, _ in }, tool: { _, _ in Data() })
            Issue.record("Expected failed child")
        } catch {
            #expect(await runner.active == 0)
            #expect(await runner.started.count == 2, "Queued work must not start after a sibling fails")
        }
    }

    @MainActor @Test func queuedToolCancellationCannotEnterTheWriteLane() async throws {
        let lane = CollaborationToolLane()
        let entered = TestGate(), release = TestGate(), queued = TestGate()
        var writes: [Int] = []
        let first = Task {
            try await lane.perform {
                entered.open()
                guard await release.waitUntilOpen() else { throw PiAgentFailure.timedOut }
                writes.append(1)
                return Data()
            }
        }
        defer { release.open(); first.cancel() }
        #expect(await entered.waitUntilOpen())
        let second = Task {
            queued.open()
            return try await lane.perform { writes.append(2); return Data() }
        }
        defer { second.cancel() }
        #expect(await queued.waitUntilOpen())
        second.cancel(); release.open()
        _ = try await first.value
        do { _ = try await second.value; Issue.record("Cancelled queued tool must fail") }
        catch { #expect(error is CancellationError) }
        #expect(writes == [1])
    }
}

private actor SchedulingControlledPi: PiAgentRunning {
    nonisolated let twoStarted = TestGate()
    nonisolated let release = TestGate()
    let failFirst: Bool
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var started: [String] = []
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        active += 1; maximumActive = max(maximumActive, active); started.append(request.runID)
        defer { active -= 1 }
        if active == 2 { twoStarted.open() }
        if failFirst && request.runID == "0" {
            guard await twoStarted.waitUntilOpen() else { throw PiAgentFailure.timedOut }
            throw PiAgentFailure.modelFailed
        }
        guard await release.waitUntilOpen() else {
            try Task.checkCancellation()
            throw PiAgentFailure.timedOut
        }
        try Task.checkCancellation()
        return request.runID
    }
}
