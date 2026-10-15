import CryptoKit
import Darwin
import Foundation
import LitheCoreContracts

/// Platform process/file ownership; the worker receives no source path or shell
/// capability. See shared/contracts/pi-bridge.md for the pinned wire boundary.
struct MacPiAgentRunner: PiAgentRunning {
    let files: any FileStorage
    let credentials: any AIProviderCredentialResolver
    var runtimeDirectory: URL? = nil
    var nodeExecutable: URL? = nil
    var runtimeStore: MacPiRuntimeStore? = nil
    var sandboxProfile: URL? = nil

    func run(_ request: PiAgentRequest,
             onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        try Task.checkCancellation()
        if runtimeDirectory == nil, let runtimeStore {
            guard sandboxProfile != nil else { throw PiAgentFailure.incompatibleRuntime }
            let lease = try await runtimeStore.acquire()
            var pinned = self
            pinned.runtimeDirectory = lease.directory; pinned.runtimeStore = nil
            do {
                let result = try await pinned.run(request, onEvent: onEvent, tool: tool)
                await runtimeStore.release(lease)
                return result
            } catch {
                await runtimeStore.release(lease)
                throw error
            }
        }
        guard let runtime = runtimeDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("PiRuntime"),
              files.fileExists(at: runtime.appendingPathComponent("src/main.mjs")) else { throw PiAgentFailure.runtimeUnavailable }
        let node = (nodeExecutable ?? runtime.appendingPathComponent("bin/node")).resolvingSymlinksInPath()
        // Production policy belongs to the signed host, never an imported
        // executable package. Tests may supply their fixed fixture profile.
        let profile = sandboxProfile ?? runtime.appendingPathComponent("platform/macos.sb")
        guard files.fileExists(at: node), files.fileExists(at: profile) else { throw PiAgentFailure.incompatibleRuntime }
        let provider = request.provider
        guard provider.isValid, !provider.usesInsecureHTTP || provider.allowsInsecureHTTP,
              let endpoint = provider.endpointURL, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw CollaborationRequestFailure.configuration }
        let key = credentials.readAPIKey(for: provider) ?? ""
        guard !key.isEmpty || !provider.requiresAPIKey else { throw CollaborationRequestFailure.configuration }
        let workspaceID = SHA256.hash(data: Data(request.workspace.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let state = files.applicationSupportDirectory().appendingPathComponent("Lithe/Pi/Sessions/\(workspaceID)/\(UUID().uuidString)")
        try files.createDirectory(at: state, withIntermediateDirectories: true)
        let canonicalState = state.resolvingSymlinksInPath()
        defer { try? files.removeItem(at: state) }
        let input = Pipe(), output = Pipe(), diagnostic = Pipe()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            diagnostic.fileHandleForReading.readabilityHandler = nil
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           output.fileHandleForReading, output.fileHandleForWriting,
                           diagnostic.fileHandleForReading, diagnostic.fileHandleForWriting] { try? handle.close() }
        }
        _ = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process = MacManagedProcess(executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-D", "STATE=\(canonicalState.path)", "-D", "NODE=\(node.path)", "-f", profile.path, node.path,
                        "--permission", "--allow-fs-read=\(runtime.resolvingSymlinksInPath().path)",
                        "--allow-fs-read=\(canonicalState.path)", "--allow-fs-write=\(canonicalState.path)",
                        runtime.appendingPathComponent("src/main.mjs").path],
            currentDirectoryURL: canonicalState,
            environment: ["PATH": node.deletingLastPathComponent().path, "HOME": canonicalState.path, "TMPDIR": canonicalState.path],
            standardInput: input.fileHandleForReading, standardOutput: output.fileHandleForWriting,
            standardError: diagnostic.fileHandleForWriting)
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(128))
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; continuation.finish(); return }
            if case .dropped = continuation.yield(data) {
                process.terminate(gracePeriod: .zero)
                continuation.finish()
            }
        }
        diagnostic.fileHandleForReading.readabilityHandler = { handle in
            // Drain stderr without exposing provider/SDK internals to the UI or logs.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(max(1, min(request.timeoutSeconds, 3600)) + 10)) }
            catch { return }
            process.terminate(gracePeriod: .seconds(2))
            continuation.finish()
        }
        defer { deadline.cancel(); continuation.finish() }
        do {
            return try await withTaskCancellationHandler {
                try process.run()
                try input.fileHandleForReading.close()
                try output.fileHandleForWriting.close()
                try diagnostic.fileHandleForWriting.close()
                try Task.checkCancellation()
                let result = try await communicate(request, endpoint: endpoint, key: key, input: input.fileHandleForWriting,
                                                   chunks: chunks, onEvent: onEvent, tool: tool)
                if let cleanup = process.terminate(gracePeriod: .seconds(2)), !(await cleanup.value) {
                    throw PiAgentFailure.processFailed
                }
                return result
            } onCancel: {
                // SIGTERM invokes the worker's clearQueue -> abort -> dispose path.
                // The managed process group escalates if the SDK does not drain.
                process.terminate(gracePeriod: .seconds(2))
                continuation.finish()
            }
        } catch {
            if let cleanup = process.terminate(gracePeriod: .seconds(2)), !(await cleanup.value) {
                throw PiAgentFailure.processFailed
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func communicate(_ request: PiAgentRequest, endpoint: URL, key: String, input: FileHandle,
                             chunks: AsyncStream<Data>, onEvent: @escaping @Sendable (PiAgentEvent) async -> Void,
                             tool: @escaping @Sendable (PiToolRequest) async throws -> Data) async throws -> String {
        var base = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = "/" + request.provider.apiProtocol.endpointSuffix
        if base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        let api: String
        switch request.provider.apiProtocol {
        case .responses: api = "openai-responses"
        case .chatCompletions: api = "openai-completions"
        case .anthropicMessages: api = "anthropic-messages"
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= 4 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
            data.append(10)
            try input.write(contentsOf: data)
        }
        try send(["type": "initialize", "requestId": "initialize", "protocolVersion": 1,
                  "configuration": ["role": request.role.rawValue, "systemPrompt": request.system,
                    "runTimeoutMs": request.timeoutSeconds * 1000,
                    "tokenBudget": max(128, min(request.tokenBudget, 2_000_000)),
                    "model": ["api": api, "id": request.provider.model, "baseUrl": base,
                              "apiKey": key.isEmpty ? "lithe-local-no-auth" : key,
                              "authentication": key.isEmpty ? "none" : request.provider.authentication.rawValue,
                              "maxTokens": max(128, min(request.maximumOutputTokens, 64_000)),
                              "allowInsecureHTTP": request.provider.allowsInsecureHTTP]]])
        var pending = Data(), text = "", sequence = 0, ready = false, completed = false
        for await chunk in chunks {
            try Task.checkCancellation()
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                guard end <= 4 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
                let data = Data(pending[..<end]); pending.removeSubrange(...end)
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["protocolVersion"] as? Int == 1, let next = value["sequence"] as? Int, next == sequence + 1,
                      let type = value["type"] as? String else { throw PiAgentFailure.protocolFailure }
                sequence = next
                switch type {
                case "ready":
                    guard !ready, value["role"] as? String == request.role.rawValue else { throw PiAgentFailure.protocolFailure }
                    ready = true
                    try send(["type": "prompt", "requestId": "prompt", "runId": request.runID, "text": request.prompt])
                case "event":
                    let event = try JSONDecoder().decode(PiAgentEvent.self, from: data)
                    guard ready, event.runId == request.runID else { throw PiAgentFailure.protocolFailure }
                    if event.kind == "text_delta", let delta = event.text {
                        text += delta
                        guard text.utf8.count <= 4 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
                    }
                    await onEvent(event)
                case "tool_request":
                    let call = try JSONDecoder().decode(PiToolRequest.self, from: data)
                    guard ready, call.runId == request.runID else { throw PiAgentFailure.protocolFailure }
                    do {
                        let result = try await tool(call)
                        try Task.checkCancellation()
                        guard result.count <= 3 * 1024 * 1024,
                              let payload = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw PiAgentFailure.outputLimit }
                        try send(["type": "tool_result", "requestId": UUID().uuidString, "runId": request.runID,
                                  "toolCallId": call.toolCallId, "ok": true, "result": payload])
                    } catch {
                        try Task.checkCancellation()
                        guard (error as? PiAgentFailure) == .toolDenied else { throw error }
                        try send(["type": "tool_result", "requestId": UUID().uuidString, "runId": request.runID,
                                  "toolCallId": call.toolCallId, "ok": false, "code": "host_operation_rejected"])
                    }
                case "run_finished":
                    guard value["runId"] as? String == request.runID else { throw PiAgentFailure.protocolFailure }
                    switch value["outcome"] as? String {
                    case "completed":
                        if let finalText = value["text"] as? String {
                            guard finalText.utf8.count <= 4 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
                            text = finalText
                        }
                        completed = true
                    case "cancelled": throw CancellationError()
                    case "timeout": throw PiAgentFailure.timedOut
                    case "budgetExceeded": throw PiAgentFailure.outputLimit
                    default: throw PiAgentFailure.modelFailed
                    }
                    try send(["type": "shutdown", "requestId": "shutdown"])
                case "closed":
                    guard completed else { throw PiAgentFailure.protocolFailure }
                case "error": throw PiAgentFailure.protocolFailure
                case "accepted", "tool_ack": break
                default: throw PiAgentFailure.protocolFailure
                }
            }
            guard pending.count <= 4 * 1024 * 1024 else { throw PiAgentFailure.outputLimit }
        }
        try Task.checkCancellation()
        guard completed, pending.isEmpty else { throw PiAgentFailure.protocolFailure }
        return text
    }
}
