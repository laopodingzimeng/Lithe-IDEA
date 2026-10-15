import CryptoKit
import Darwin
import Foundation

/// Immutable, content-addressed runtime copies. Only selection metadata changes
/// after installation; leases prevent a model session from changing its engine.
actor MacPiRuntimeStore: PiRuntimeManaging {
    struct Lease: Sendable { let id: UUID; let directory: URL }
    private struct FileDigest: Codable, Equatable { let sha256: String; let bytes: Int64 }
    private struct Manifest: Codable {
        let schemaVersion: Int; let version: String; let protocolVersion: Int
        let sdkVersion: String; let nodeVersion: String; let platform: String; let architecture: String
        let files: [String: FileDigest]
    }
    private struct Selection: Codable { let id: String }
    private let directory: URL
    private let bundledDirectory: URL?
    private let architecture: String
    private let manager = FileManager.default
    private var selectedID = "bundled"
    private var selectionLoaded = false
    private var pendingID: String?
    private var leases: [UUID: String] = [:]
    private var lastMessage: String?
    private var storageLock: RuntimeStorageLock?
    private var recoveredStaging = false
    private var cachedVersions: [PiRuntimeVersion] = []
    private var observers: [UUID: AsyncStream<PiRuntimeStatus>.Continuation] = [:]
    private static let manifestName = "lithe-pi-runtime.json"
    private static let maximumBytes: Int64 = 512 * 1024 * 1024

    init(storageDirectory: URL, bundledDirectory: URL?, architecture: String = MacPiRuntimeStore.hostArchitecture) {
        self.directory = storageDirectory.standardizedFileURL
        self.bundledDirectory = bundledDirectory
        self.architecture = architecture
    }
    nonisolated static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }
    private var versionsDirectory: URL { directory.appendingPathComponent("Versions") }
    private var selectionURL: URL { directory.appendingPathComponent("active.json") }

    func updates() -> AsyncStream<PiRuntimeStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PiRuntimeStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(snapshot())
        return stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func snapshot() -> PiRuntimeStatus {
        .init(versions: cachedVersions, selectedID: selectedID, pendingID: pendingID, activeRuns: leases.count, message: lastMessage)
    }
    private func publish() { for observer in observers.values { observer.yield(snapshot()) } }

    func status() async throws -> PiRuntimeStatus {
        try lockStorage()
        defer { unlockIfIdle() }
        try loadSelection()
        var versions: [PiRuntimeVersion] = [], message = lastMessage
        if let bundledDirectory, manager.fileExists(atPath: bundledDirectory.path) {
            do { versions.append(version(try validate(bundledDirectory), id: "bundled")) }
            catch is CancellationError { throw CancellationError() }
            catch { versions.append(unavailableVersion(id: "bundled")); message = "内置运行包校验失败，可导入兼容运行包。" }
        }
        if manager.fileExists(atPath: versionsDirectory.path) {
            for url in try manager.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = url.lastPathComponent
                guard Self.isDigest(id) else { continue }
                do { versions.append(version(try validate(url, expectedDigest: id), id: id)) }
                catch is CancellationError { throw CancellationError() }
                catch { versions.append(unavailableVersion(id: id)); message = "有导入的运行包校验失败，已禁止使用；请重新导入或切换后移除。" }
            }
        }
        cachedVersions = versions; lastMessage = message
        publish()
        return snapshot()
    }

    func install(directory source: URL) async throws -> PiRuntimeStatus {
        try Task.checkCancellation()
        try lockStorage()
        defer { unlockIfIdle() }
        _ = try validate(source)
        let id = try hash(source.appendingPathComponent(Self.manifestName))
        try manager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let installed = versionsDirectory.appendingPathComponent(id)
        let exists = manager.fileExists(atPath: installed.path)
        if exists, (try? validate(installed, expectedDigest: id)) != nil {
            return try await select(id: id)
        }
        guard !leases.values.contains(id) else { throw PiRuntimeFailure.inUse }
        if !exists {
            let existing = try manager.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil)
                .filter { Self.isDigest($0.lastPathComponent) }
            guard existing.count < 8 else { throw PiRuntimeFailure.capacity }
        }
        let staging = directory.appendingPathComponent("install-\(UUID().uuidString)")
        let backup = directory.appendingPathComponent("replaced-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try copyBounded(source, to: staging)
        try Task.checkCancellation()
        _ = try validate(staging, expectedDigest: id)
        // Repair only a corrupt, unleased copy. A failed publish restores the old
        // directory; the active pointer always refers to the same content ID.
        if exists { try manager.moveItem(at: installed, to: backup) }
        do { try manager.moveItem(at: staging, to: installed) }
        catch {
            if exists { try manager.moveItem(at: backup, to: installed) }
            throw error
        }
        if exists { try manager.removeItem(at: backup) }
        return try await select(id: id)
    }

    func select(id: String) async throws -> PiRuntimeStatus {
        try lockStorage()
        defer { unlockIfIdle() }
        try loadSelection()
        _ = try resolve(id)
        if leases.isEmpty { try saveSelection(id); pendingID = nil }
        else { pendingID = id }
        lastMessage = nil
        return try await status()
    }

    func remove(id: String) async throws -> PiRuntimeStatus {
        try lockStorage()
        defer { unlockIfIdle() }
        try loadSelection()
        guard Self.isDigest(id), id != selectedID, id != pendingID, !leases.values.contains(id) else {
            throw PiRuntimeFailure.inUse
        }
        try manager.removeItem(at: versionsDirectory.appendingPathComponent(id))
        return try await status()
    }

    func acquire() throws -> Lease {
        try Task.checkCancellation()
        try lockStorage()
        defer { unlockIfIdle() }
        try loadSelection()
        let runtime = try resolve(selectedID)
        let lease = Lease(id: UUID(), directory: runtime)
        leases[lease.id] = selectedID
        publish()
        return lease
    }
    func release(_ lease: Lease) async {
        defer { unlockIfIdle() }
        leases[lease.id] = nil
        // A cancelled model request still owns this cleanup. The explicitly
        // drained task lets validation finish without inheriting its cancellation.
        await Task { applyPendingSelection() }.value
        publish()
    }
    private func applyPendingSelection() {
        guard leases.isEmpty, let pendingID else { return }
        defer { unlockIfIdle() }
        do { try lockStorage(); try loadSelection(); _ = try resolve(pendingID); try saveSelection(pendingID); self.pendingID = nil; lastMessage = nil }
        catch { self.pendingID = nil; lastMessage = "运行包切换未完成，仍保留原版本。请检查导入内容后重试。" }
    }

    private func loadSelection() throws {
        guard !selectionLoaded else { return }
        if manager.fileExists(atPath: selectionURL.path) {
            do {
                let selection = try JSONDecoder().decode(Selection.self, from: boundedRead(selectionURL, maximum: 1024))
                guard selection.id == "bundled" || Self.isDigest(selection.id) else { throw PiAgentFailure.incompatibleRuntime }
                selectedID = selection.id
            } catch {
                // Keep the corrupt pointer on disk for diagnosis until an explicit
                // selection replaces it; a broken preference cannot lock out repair.
                lastMessage = "运行包选择记录损坏，暂用内置版本。请重新选择可用版本。"
            }
        }
        selectionLoaded = true
    }
    private func lockStorage() throws {
        guard storageLock == nil else { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        storageLock = try RuntimeStorageLock(url: directory.appendingPathComponent("runtime.lock"))
        if !recoveredStaging {
            do {
                // The exclusive lock proves no other instance owns these stages.
                // Replaced copies were already corrupt, so neither is a fallback.
                for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    let name = url.lastPathComponent
                    let prefix = name.hasPrefix("install-") ? "install-" : name.hasPrefix("replaced-") ? "replaced-" : ""
                    if !prefix.isEmpty, UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
                        try manager.removeItem(at: url)
                    }
                }
                recoveredStaging = true
            } catch { storageLock = nil; throw error }
        }
        selectionLoaded = false
        selectedID = "bundled"
    }
    private func unlockIfIdle() {
        if leases.isEmpty { storageLock = nil }
    }
    private func saveSelection(_ id: String) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Selection(id: id)).write(to: selectionURL, options: .atomic)
        selectedID = id
    }
    private func resolve(_ id: String) throws -> URL {
        let url: URL
        if id == "bundled" {
            guard let bundledDirectory else { throw PiAgentFailure.runtimeUnavailable }
            url = bundledDirectory
        } else {
            guard Self.isDigest(id) else { throw PiAgentFailure.incompatibleRuntime }
            url = versionsDirectory.appendingPathComponent(id)
        }
        guard manager.fileExists(atPath: url.path) else { throw PiAgentFailure.runtimeUnavailable }
        _ = try validate(url, expectedDigest: id == "bundled" ? nil : id)
        return url
    }
    private func version(_ manifest: Manifest, id: String) -> PiRuntimeVersion {
        .init(id: id, version: manifest.version, sdkVersion: manifest.sdkVersion, nodeVersion: manifest.nodeVersion, bundled: id == "bundled")
    }
    private func unavailableVersion(id: String) -> PiRuntimeVersion {
        .init(id: id, version: id == "bundled" ? "内置运行包" : "损坏的运行包 · " + id.prefix(8),
              sdkVersion: "", nodeVersion: "", bundled: id == "bundled", available: false)
    }

    private func validate(_ root: URL, expectedDigest: String? = nil) throws -> Manifest {
        let manifestURL = root.appendingPathComponent(Self.manifestName)
        let bytes = try boundedRead(manifestURL, maximum: 4 * 1024 * 1024)
        if let expectedDigest, Self.digest(bytes) != expectedDigest { throw PiAgentFailure.incompatibleRuntime }
        let value = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard value.schemaVersion == 1, value.protocolVersion == 1, value.platform == "darwin", value.architecture == architecture,
              value.version.range(of: #"^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$"#, options: .regularExpression) != nil,
              value.nodeVersion.range(of: #"^24\.\d+\.\d+$"#, options: .regularExpression) != nil,
              value.sdkVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              !value.files.isEmpty, value.files.count <= 20_000 else { throw PiAgentFailure.incompatibleRuntime }
        let required = ["src/main.mjs", "platform/macos.sb", "bin/node", "package.json", "package-lock.json",
                        "node_modules/@earendil-works/pi-coding-agent/package.json"]
        guard required.allSatisfy({ value.files[$0] != nil }), value.files[Self.manifestName] == nil else {
            throw PiAgentFailure.incompatibleRuntime
        }
        let entries = try inventory(root)
        guard Set(entries.keys).subtracting([Self.manifestName]) == Set(value.files.keys) else { throw PiAgentFailure.incompatibleRuntime }
        for (path, file) in value.files {
            try Task.checkCancellation()
            guard Self.safePath(path), Self.isDigest(file.sha256), file.bytes >= 0, entries[path] == file.bytes,
                  try hash(root.appendingPathComponent(path)) == file.sha256 else { throw PiAgentFailure.incompatibleRuntime }
        }
        struct SDK: Decodable { let version: String }
        let sdk = try JSONDecoder().decode(SDK.self, from: boundedRead(root.appendingPathComponent(required[5]), maximum: 1024 * 1024))
        guard sdk.version == value.sdkVersion, manager.isExecutableFile(atPath: root.appendingPathComponent("bin/node").path) else {
            throw PiAgentFailure.incompatibleRuntime
        }
        return value
    }

    private func inventory(_ root: URL) throws -> [String: Int64] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var enumerationFailed = false
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw PiAgentFailure.incompatibleRuntime
        }
        var entries: [String: Int64] = [:], count = 0, total: Int64 = 0
        let prefix = root.standardizedFileURL.path + "/"
        for case let file as URL in iterator {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000, file.standardizedFileURL.path.hasPrefix(prefix) else { throw PiAgentFailure.incompatibleRuntime }
            let path = String(file.standardizedFileURL.path.dropFirst(prefix.count))
            let metadata = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard Self.safePath(path), metadata.isSymbolicLink != true else { throw PiAgentFailure.incompatibleRuntime }
            if metadata.isDirectory == true { continue }
            guard metadata.isRegularFile == true, let size = metadata.fileSize, size >= 0 else { throw PiAgentFailure.incompatibleRuntime }
            total += Int64(size)
            guard total <= Self.maximumBytes else { throw PiAgentFailure.incompatibleRuntime }
            entries[path] = Int64(size)
        }
        guard !enumerationFailed else { throw PiAgentFailure.incompatibleRuntime }
        return entries
    }

    private func copyBounded(_ source: URL, to destination: URL) throws {
        let entries = try inventory(source)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        var total: Int64 = 0
        for path in entries.keys.sorted() {
            try Task.checkCancellation()
            let inputURL = source.appendingPathComponent(path), outputURL = destination.appendingPathComponent(path)
            guard try inputURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw PiAgentFailure.incompatibleRuntime }
            try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: outputURL.path, contents: nil) else { throw PiAgentFailure.incompatibleRuntime }
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            var size: Int64 = 0
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                size += Int64(data.count); total += Int64(data.count)
                guard size <= entries[path]!, total <= Self.maximumBytes else { throw PiAgentFailure.incompatibleRuntime }
                try output.write(contentsOf: data)
            }
            guard size == entries[path] else { throw PiAgentFailure.incompatibleRuntime }
            try manager.setAttributes([.posixPermissions: path == "bin/node" ? 0o755 : 0o644], ofItemAtPath: outputURL.path)
        }
    }
    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let metadata = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, metadata.isRegularFile == true,
              let size = metadata.fileSize, size <= maximum else { throw PiAgentFailure.incompatibleRuntime }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw PiAgentFailure.incompatibleRuntime }
        return data
    }
    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(), total: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= Self.maximumBytes else { throw PiAgentFailure.incompatibleRuntime }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func safePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\\") && !value.contains(":") &&
        !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }
    }
}

/// A nonblocking kernel lock covers all windows and extra application processes.
/// It is held while any model uses a runtime; process death releases it naturally.
private final class RuntimeStorageLock: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PiRuntimeFailure.ownedElsewhere }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw PiRuntimeFailure.ownedElsewhere
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
}
