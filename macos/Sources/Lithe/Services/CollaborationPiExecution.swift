import Foundation

/// Pi owns each tool loop. This host scheduler only limits independent sessions,
/// preserves result order and drains siblings before returning an error.
struct CollaborationPiExecution: Sendable {
    let runner: any PiAgentRunning

    func run(_ requests: [PiAgentRequest], parallelism: Int,
             event: @escaping @Sendable (Int, PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (Int, PiToolRequest) async throws -> Data) async throws -> [String] {
        guard !requests.isEmpty, requests.count <= 8 else { throw PiAgentFailure.toolDenied }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            var results = Array(repeating: "", count: requests.count)
            func enqueue(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let value = try await runner.run(requests[index], onEvent: { await event(index, $0) },
                                                    tool: { try await tool(index, $0) })
                    return (index, value)
                }
            }
            for index in 0..<min(requests.count, max(1, min(parallelism, 8))) { enqueue(index); next += 1 }
            do {
                while let (index, result) = try await group.next() {
                    results[index] = result
                    try Task.checkCancellation()
                    if next < requests.count { enqueue(next); next += 1 }
                }
            } catch { group.cancelAll(); throw error }
            return results
        }
    }
}

/// One journal exists per workspace. Hold its lane through async editor holds,
/// disk mutation and receipt persistence, including when a sibling is cancelled.
@MainActor
final class CollaborationToolLane {
    private var tail: Task<Void, Never>?

    func perform(_ operation: @escaping @MainActor () async throws -> Data) async throws -> Data {
        let previous = tail
        let next = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = await next.result }
        return try await withTaskCancellationHandler { try await next.value } onCancel: { next.cancel() }
    }
}
