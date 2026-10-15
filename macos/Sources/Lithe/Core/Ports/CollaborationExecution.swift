import Foundation
import LitheCoreContracts

/// Stable guidance shared by the panel and its request service. Do not show
/// upstream bodies, endpoints with query credentials, or transport internals.
enum CollaborationRequestFailure: LocalizedError {
    case timedOut, network, configuration, invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .timedOut: "模型在 180 秒内未完成响应，需求已保留。可先测试连接，或关闭附带代码后重试。"
        case .network: "无法连接 AI 服务商。请在模型设置中测试连接，检查网络和 API 地址后重试。"
        case .configuration: "当前模型配置不完整。请检查服务商、模型、密钥及 HTTP 许可，再测试连接。"
        case .invalidResponse: "模型未返回有效内容。请检查接口协议和模型，再重试。"
        case .http(401): "认证失败（401）。请检查当前服务商的密钥和认证方式。"
        case .http(403): "没有调用权限（403）。请检查账户是否有权使用当前模型。"
        case .http(404): "接口或模型不存在（404）。请核对 API 地址、接口协议与模型名称。"
        case .http(429): "请求受限（429）。请检查额度，或稍后重试。"
        case .http(let status): "AI 服务商返回错误（\(status)）。需求已保留，请检查服务状态后重试。"
        }
    }
}

/// Planning needs a bounded sample, not eight entire source files. Paths and
/// truncation markers count toward the budget, so callers cannot bypass it.
enum CollaborationPlanningContext {
    static let maximumCharacters = 24_000
    static let maximumFileCharacters = 6_000
    static func render(_ files: [CollaborationFile]) -> String {
        var result = ""
        for file in files.prefix(8) {
            guard let source = file.text else { continue }
            let remaining = maximumCharacters - result.count
            let header = "\n\n文件：\(file.path)\n"
            let marker = "\n[代码已截断；不得推断未提供的方法或实现]"
            let available = min(maximumFileCharacters, remaining - header.count - marker.count)
            guard available > 0 else { break }
            let sample = String(source.prefix(available + 1))
            result += header + String(sample.prefix(available))
            if sample.count > available { result += marker }
        }
        return result
    }
}

struct CollaborationFile: Codable, Sendable, Equatable {
    let path: String
    let text: String?
    enum CodingKeys: String, CodingKey { case path, text }
    init(path: String, text: String?) { self.path = path; self.text = text }
    // Core distinguishes explicit null (absence) from an omitted field.
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(path, forKey: .path)
        if let text { try value.encode(text, forKey: .text) } else { try value.encodeNil(forKey: .text) }
    }
}
struct CollaborationChange: Codable, Sendable {
    let target: CollaborationTarget
    let expectedText: String?
    let replacement: String?
    enum CodingKeys: String, CodingKey { case target, expectedText, replacement }
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(target, forKey: .target)
        if let expectedText { try value.encode(expectedText, forKey: .expectedText) } else { try value.encodeNil(forKey: .expectedText) }
        if let replacement { try value.encode(replacement, forKey: .replacement) } else { try value.encodeNil(forKey: .replacement) }
    }
}
struct CollaborationReceipt: Codable, Sendable {
    let planId: String
    let planVersion: UInt64
    let stepId: String
    let before: [CollaborationFile]
    let after: [CollaborationFile]
    let changes: [CollaborationChange]
    var key: String { "\(planId):\(planVersion):\(stepId)" }
}
struct CollaborationPendingWrite: Codable, Sendable {
    let receipt: CollaborationReceipt
    let plan: CollaborationPlan
    let undo: Bool
}

/// Calls only an HTTP text model; it has no Agent or process tools.
protocol CollaborationGenerating: Sendable {
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String
}
struct UnavailableCollaborationGenerator: CollaborationGenerating {
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String { throw CollaborationFailure.unavailable }
}

/// Synchronous bounded commits run while the native editor is held by its owner.
/// Platform adapters own encoding, path validation and the crash-recovery journal.
protocol CollaborationWorkspaceEditing: Sendable {
    func loadSession(workspace: URL) throws -> Data?
    func saveSession(_ data: Data?, workspace: URL) throws
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile]
    func pending(workspace: URL) throws -> CollaborationPendingWrite?
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws
    func finish(workspace: URL) throws
    func rollback(workspace: URL) throws
}
extension CollaborationWorkspaceEditing {
    func loadSession(workspace: URL) throws -> Data? { nil }
    func saveSession(_ data: Data?, workspace: URL) throws { }
}
struct UnavailableCollaborationWorkspace: CollaborationWorkspaceEditing {
    func snapshot(paths: [String], workspace: URL) throws -> [CollaborationFile] { throw CollaborationFailure.unavailable }
    func pending(workspace: URL) throws -> CollaborationPendingWrite? { nil }
    func apply(_ intent: CollaborationPendingWrite, workspace: URL) throws { throw CollaborationFailure.unavailable }
    func finish(workspace: URL) throws { throw CollaborationFailure.unavailable }
    func rollback(workspace: URL) throws { throw CollaborationFailure.unavailable }
}
