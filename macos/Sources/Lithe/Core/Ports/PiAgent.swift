import Foundation
import LitheCoreContracts

enum PiAgentRole: String, Codable, Sendable {
    case development, planning, review, presentation, completion
}

struct PiAgentRequest: Sendable {
    let runID: String
    let role: PiAgentRole
    let workspace: URL
    let provider: AIProviderProfile
    let system: String
    let prompt: String
    var timeoutSeconds: Int = 600
    var maximumOutputTokens: Int = 8192
    var tokenBudget: Int = 200_000
}

struct PiToolArguments: Codable, Sendable {
    var directory: String? = nil
    var cursor: String? = nil
    var target: CollaborationTarget? = nil
    var query: String? = nil
    var changes: [CollaborationChange]? = nil
    var actionId: String? = nil
}

struct PiToolRequest: Decodable, Sendable {
    let runId: String
    let toolCallId: String
    let name: String
    let arguments: PiToolArguments
}

struct PiAgentEvent: Decodable, Sendable {
    let runId: String
    let kind: String
    var text: String? = nil
    var toolCallId: String? = nil
    var name: String? = nil
    var isError: Bool? = nil
    var tokens: [String: Double]? = nil
}

/// Each request pins a role/provider and owns an isolated Pi session. Tool replies
/// are host-produced JSON objects, never arbitrary model-selected native commands.
protocol PiAgentRunning: Sendable {
    func run(_ request: PiAgentRequest,
             onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String
}

enum PiAgentFailure: String, LocalizedError, Sendable {
    case runtimeUnavailable, incompatibleRuntime, protocolFailure, modelFailed, toolDenied, timedOut, outputLimit, processFailed
    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "Pi 运行包尚未安装，请在协作设置中安装兼容运行包。"
        case .incompatibleRuntime: "Pi 运行包不兼容或校验失败，请重新安装。"
        case .protocolFailure: "Pi 通信中断，已停止任务。请检查修改记录后重试。"
        case .modelFailed: "模型请求失败，请测试此角色的连接、协议和模型权限。"
        case .toolDenied: "该操作不在当前任务的授权范围内。"
        case .timedOut: "任务达到本次运行预算，已停止；已有修改保留在记录中。"
        case .outputLimit: "本轮调用或输出达到预算上限，已停止；已有修改保留在记录中。"
        case .processFailed: "Pi 进程未能正常退出。任务已停止，请检查修改记录。"
        }
    }
}

struct UnavailablePiAgentRunner: PiAgentRunning {
    func run(_ request: PiAgentRequest, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        throw PiAgentFailure.runtimeUnavailable
    }
}
