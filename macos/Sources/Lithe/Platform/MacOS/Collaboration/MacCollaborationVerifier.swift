import Combine
import CryptoKit
import Foundation
import LitheCoreContracts
import LitheExecutionModule

/// Runs the existing test subsystem in a bounded copy. All build/test descendants
/// inherit OS write restrictions, including project-provided Maven plugins/scripts.
@MainActor
final class MacCollaborationVerifier: CollaborationVerifying {
    private let files: any FileStorage
    private let makeTests: (any StreamingProcess) -> LanguageTestService
    init(files: any FileStorage, makeTests: @escaping (any StreamingProcess) -> LanguageTestService) {
        self.files = files; self.makeTests = makeTests
    }

    func verify(workspace: URL, actionID: String) async throws -> CollaborationVerificationResult {
        guard actionID == "java-tests", files.fileExists(at: workspace.appendingPathComponent("pom.xml")) else {
            throw PiAgentFailure.toolDenied
        }
        let id = UUID().uuidString
        let state = files.cacheDirectory().appendingPathComponent("Lithe/Pi/Validation/\(id)")
        let storage = files
        let copying = Task.detached(priority: .utility) {
            try MacVerificationSnapshot.create(workspace: workspace, state: state, files: storage)
        }
        let snapshot = try await withTaskCancellationHandler { try await copying.value } onCancel: { copying.cancel() }
        defer { try? files.removeItem(at: state) }
        try Task.checkCancellation()
        let process = MacRestrictedTestProcess(state: state)
        let tests = makeTests(process)
        let completion = MacVerificationCompletion()
        let subscription = tests.$state.sink { value in
            guard value != .idle, value != .running else { return }
            completion.finish(value)
        }
        defer { subscription.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                guard tests.run(providerID: "java", scope: .workspace, workspaceURL: snapshot.root,
                                projectFiles: snapshot.files) else { throw PiAgentFailure.processFailed }
                let state = try await completion.wait()
                try Task.checkCancellation()
                guard await process.drain() else { throw PiAgentFailure.processFailed }
                let outcome: String, code: Int32?
                switch state {
                case .passed: outcome = "passed"; code = 0
                case .failed(let exit): outcome = "failed"; code = exit
                case .timedOut: outcome = "timeout"; code = nil
                case .cancelled: outcome = "cancelled"; code = nil
                default: throw PiAgentFailure.processFailed
                }
                return CollaborationVerificationResult(executionID: id, actionID: actionID,
                    sourceRevision: snapshot.revision, outcome: outcome, exitCode: code,
                    output: String(tests.output.suffix(32_000)))
            } onCancel: {
                Task { @MainActor in tests.stop(); completion.cancel() }
            }
            return result
        } catch {
            tests.stop()
            guard await process.drain() else { throw PiAgentFailure.processFailed }
            throw error
        }
    }
}

private struct MacVerificationSnapshot: Sendable {
    let root: URL
    let files: [URL]
    let revision: String
    static func create(workspace: URL, state: URL, files: any FileStorage) throws -> Self {
        let source = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let root = state.appendingPathComponent("project")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var pending = [""], copied: [URL] = [], bytes = 0, directories = 0, hash = SHA256()
        let excluded: Set<String> = [".git", ".artifacts", "node_modules", ".build", "dist", ".idea"]
        do {
            while let directory = pending.popLast() {
                try Task.checkCancellation()
                let entries = try FileManager.default.contentsOfDirectory(at: source.appendingPathComponent(directory),
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for entry in entries {
                    try Task.checkCancellation()
                    if directory.isEmpty && excluded.contains(entry.lastPathComponent) { continue }
                    if entry.lastPathComponent == "target", files.fileExists(at: entry.deletingLastPathComponent().appendingPathComponent("pom.xml")) { continue }
                    let relative = directory.isEmpty ? entry.lastPathComponent : directory + "/" + entry.lastPathComponent
                    let metadata = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard metadata.isSymbolicLink != true else { throw PiAgentFailure.toolDenied }
                    let destination = root.appendingPathComponent(relative)
                    if metadata.isDirectory == true {
                        directories += 1
                        guard directories < 20_000 else { throw PiAgentFailure.outputLimit }
                        try files.createDirectory(at: destination, withIntermediateDirectories: true)
                        pending.append(relative)
                    } else {
                        let data = try files.readPrefix(from: entry, byteCount: 8 * 1024 * 1024 + 1)
                        bytes += data.count
                        guard data.count <= 8 * 1024 * 1024, bytes <= 128 * 1024 * 1024, copied.count < 20_000 else { throw PiAgentFailure.outputLimit }
                        try files.writeData(data, to: destination, options: .atomic)
                        hash.update(data: Data((relative + "\0" + String(data.count) + "\0").utf8)); hash.update(data: data)
                        copied.append(destination)
                    }
                }
            }
            // The fingerprint identifies precisely what was copied, not a claim
            // that a concurrently edited original workspace still has this version.
            return .init(root: root, files: copied, revision: hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch { try? files.removeItem(at: state); throw error }
    }
}

private final class MacRestrictedTestProcess: StreamingProcess, @unchecked Sendable {
    private let process = MacStreamingProcess()
    private let state: URL
    private var cleanup: Task<Bool, Never>?
    init(state: URL) { self.state = state.resolvingSymlinksInPath() }
    var isRunning: Bool { process.isRunning }
    var onOutput: (@Sendable (String) -> Void)? { get { process.onOutput } set { process.onOutput = newValue } }
    var onTermination: (@Sendable (Int32) -> Void)? { get { process.onTermination } set { process.onTermination = newValue } }
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)? { get { process.onStateChange } set { process.onStateChange = newValue } }
    func start(_ request: ProcessRequest) throws {
        let profile = "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath (param \"STATE\")))(allow file-write-data (literal \"/dev/null\"))"
        var environment = request.environment ?? [:]
        // Only the runtime resolver's executable/JDK paths and locale are retained.
        environment = environment.filter { ["PATH", "JAVA_HOME", "LANG", "LC_ALL"].contains($0.key) }
        environment["HOME"] = state.path; environment["TMPDIR"] = state.path
        let escaped = state.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        environment["MAVEN_OPTS"] = "-Duser.home=\"\(escaped)\" -Djava.io.tmpdir=\"\(escaped)\""
        try process.start(ProcessRequest(operationID: request.operationID, executablePath: "/usr/bin/sandbox-exec",
            arguments: ["-D", "STATE=\(state.path)", "-p", profile, request.executablePath,
                        "-Dmaven.repo.local=\(state.appendingPathComponent("repository").path)"] + request.arguments,
            workingDirectory: request.workingDirectory, environment: environment,
            timeoutMilliseconds: min(request.timeoutMilliseconds ?? 120_000, 120_000)))
    }
    func send(_ input: Data) throws { try process.send(input) }
    func stop() {
        guard cleanup == nil else { return }
        cleanup = Task { await process.stopAndWait() }
    }
    func drain() async -> Bool { stop(); return await cleanup?.value ?? true }
}

@MainActor
private final class MacVerificationCompletion {
    private var outcome: LanguageTestRunState?
    private var continuation: CheckedContinuation<LanguageTestRunState, Error>?
    private var watchdog: Task<Void, Never>?
    private var cancelled = false
    func finish(_ value: LanguageTestRunState) {
        outcome = value; watchdog?.cancel(); watchdog = nil
        continuation?.resume(returning: value); continuation = nil
    }
    func cancel() {
        cancelled = true; watchdog?.cancel(); watchdog = nil
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
    func wait() async throws -> LanguageTestRunState {
        if cancelled { throw CancellationError() }
        if let outcome { return outcome }
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(135)) } catch { return }
                guard let self else { return }
                self.continuation?.resume(throwing: PiAgentFailure.timedOut); self.continuation = nil
            }
        }
    }
}
