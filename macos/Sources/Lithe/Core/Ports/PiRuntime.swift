import Foundation

struct PiRuntimeVersion: Identifiable, Sendable {
    /// Content identity, not a mutable version label. `bundled` selects the host's
    /// read-only baseline; imported packages use the accepted manifest digest.
    let id: String
    let version: String
    let sdkVersion: String
    let nodeVersion: String
    let bundled: Bool
    var available = true
}

enum PiRuntimeFailure: LocalizedError {
    case capacity, inUse, ownedElsewhere
    var errorDescription: String? {
        switch self {
        case .capacity: "已保留 8 个运行包版本。请先移除不再使用的版本，再导入新版本。"
        case .inUse: "运行包仍在使用或等待启用，请先切换版本并等待任务结束。"
        case .ownedElsewhere: "另一个 Lithe 实例正在使用运行包，请等它的协作任务结束后重试。"
        }
    }
}

struct PiRuntimeStatus: Sendable {
    let versions: [PiRuntimeVersion]
    let selectedID: String
    let pendingID: String?
    let activeRuns: Int
    var message: String? = nil
}

/// Platform adapters validate/copy user-selected packages into writable storage.
/// Selection waits for all pinned requests to exit; rollback uses the same path.
protocol PiRuntimeManaging: Sendable {
    func updates() async -> AsyncStream<PiRuntimeStatus>
    func status() async throws -> PiRuntimeStatus
    func install(directory: URL) async throws -> PiRuntimeStatus
    func select(id: String) async throws -> PiRuntimeStatus
    func remove(id: String) async throws -> PiRuntimeStatus
}

extension PiRuntimeManaging {
    func updates() async -> AsyncStream<PiRuntimeStatus> { AsyncStream { $0.finish() } }
}

struct UnavailablePiRuntimeManager: PiRuntimeManaging {
    func status() async throws -> PiRuntimeStatus { throw PiAgentFailure.runtimeUnavailable }
    func install(directory: URL) async throws -> PiRuntimeStatus { throw PiAgentFailure.runtimeUnavailable }
    func select(id: String) async throws -> PiRuntimeStatus { throw PiAgentFailure.runtimeUnavailable }
    func remove(id: String) async throws -> PiRuntimeStatus { throw PiAgentFailure.runtimeUnavailable }
}
