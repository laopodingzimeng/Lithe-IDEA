import Foundation
import LitheCoreContracts

/// SSE is presentation only until its terminal event arrives. A broken stream
/// must never turn a partial patch into a successful generation.
final class AIWorkflowStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let onText: @Sendable (String) -> Void
    private var pending = Data()
    private var eventLines: [String] = []
    private var text = ""
    private var received = 0
    private var published = 0
    private var sawEvent = false
    private var complete = false
    private var failed = false

    init(onText: @escaping @Sendable (String) -> Void) { self.onText = onText }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        received += data.count
        guard received <= 4 * 1_048_576, !failed else { failed = true; return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            var line = pending[..<newline]
            if line.last == 13 { line = line.dropLast() }
            consume(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(...newline)
        }
    }

    private func consume(_ line: String) {
        if line.hasPrefix("data:") {
            sawEvent = true
            eventLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if line.isEmpty, !eventLines.isEmpty {
            let payload = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true)
            if payload == "[DONE]" { complete = true; return }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failed = true; return
            }
            let type = object["type"] as? String ?? ""
            if object["error"] != nil || ["error", "response.failed", "response.incomplete"].contains(type) { failed = true }
            if type == "response.completed" || type == "message_stop" { complete = true }
            if type == "response.output_text.delta", let delta = object["delta"] as? String { text += delta }
            if type == "content_block_delta", let delta = object["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let value = delta["text"] as? String { text += value }
            if type == "message_delta", let delta = object["delta"] as? [String: Any],
               delta["stop_reason"] as? String == "max_tokens" { failed = true }
            if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
                if let delta = choice["delta"] as? [String: Any], let value = delta["content"] as? String { text += value }
                if let reason = choice["finish_reason"] as? String {
                    if reason == "stop" { complete = true } else { failed = true }
                }
            }
            guard text.utf8.count <= 1_048_576 else { failed = true; return }
            // Bound UI publications without timers or fabricated typing. The
            // final publication below includes a short last fragment.
            if text.utf8.count > published && (text.utf8.count - published >= 256 || text.hasSuffix("\n")) {
                published = text.utf8.count
                onText(text)
            }
        }
    }

    /// Returns nil for providers that answer the streaming request with ordinary
    /// JSON. No second (potentially billed) request is issued automatically.
    func finish(body: Data) throws -> String? {
        if received == 0 { append(body) }
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        consume("")
        guard !failed else { throw CommitMessageGenerationError.invalidResponse }
        guard sawEvent else { return nil }
        guard complete, !text.isEmpty else { throw CommitMessageGenerationError.invalidResponse }
        onText(text)
        return text
    }
}
