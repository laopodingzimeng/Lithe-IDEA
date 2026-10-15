import Foundation
import LitheCoreContracts

/// Exercises the real SDK/provider tool path against a tiny in-memory probe.
/// No project file, editor buffer or workflow receipt is touched by diagnostics.
struct CollaborationPiDiagnostics: Sendable {
    let runner: any PiAgentRunning

    func test(provider: AIProviderProfile, role: PiAgentRole, workspace: URL) async throws {
        let nonce = UUID().uuidString
        let probe = CollaborationDiagnosticProbe(nonce: nonce)
        let development = role != .presentation
        let prompt = development ? """
        测试工具协议。调用 workspace_read，target 为 {"kind":"file","path":"capability.txt"}。
        再调用 workspace_apply，将读到的原文追加 -ok；expectedText 必须等于原文，replacement 必须等于原文加 -ok。
        这是宿主内存诊断，不会修改项目。最后仅返回 JSON {"ok":true,"nonce":"读到的原文"}。
        """ : "仅返回 JSON {\"ok\":true,\"nonce\":\"\(nonce)\"}，不加代码块或前言。"
        let request = PiAgentRequest(runID: UUID().uuidString, role: development ? .development : .presentation,
            workspace: workspace, provider: provider, system: "只完成指定的模型能力诊断，不读取项目、不使用其它工具。",
            prompt: prompt, timeoutSeconds: 30, maximumOutputTokens: 1024, tokenBudget: 16_000)
        let text = try await runner.run(request, onEvent: { _ in }, tool: { call in
            guard call.runId == request.runID, development else { throw PiAgentFailure.toolDenied }
            return try await probe.perform(call)
        })
        try Task.checkCancellation()
        struct Result: Decodable { let ok: Bool; let nonce: String }
        let result = try JSONDecoder().decode(Result.self, from: CollaborationResponseJSON.data(text))
        let toolsPassed = await probe.passed
        guard result.ok, result.nonce == nonce, !development || toolsPassed else {
            throw PiAgentFailure.protocolFailure
        }
    }
}

private actor CollaborationDiagnosticProbe {
    let nonce: String
    private var read = false
    private(set) var passed = false
    init(nonce: String) { self.nonce = nonce }
    func perform(_ call: PiToolRequest) throws -> Data {
        let target = CollaborationTarget(kind: "file", path: "capability.txt")
        if call.name == "workspace_read", call.arguments.target == target {
            read = true
            struct Result: Encodable { let file: CollaborationFile; let truncated = false }
            return try JSONEncoder().encode(Result(file: .init(path: target.path, text: nonce)))
        }
        if call.name == "workspace_apply", read, let changes = call.arguments.changes, changes.count == 1,
           changes[0].target == target, changes[0].expectedText == nonce, changes[0].replacement == nonce + "-ok" {
            passed = true
            struct Result: Encodable { let diagnosticOnly = true; let sourceFilesChanged = false }
            return try JSONEncoder().encode(Result())
        }
        throw PiAgentFailure.toolDenied
    }
}
