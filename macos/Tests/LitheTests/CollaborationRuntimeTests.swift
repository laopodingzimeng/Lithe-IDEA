import CryptoKit
import Foundation
import Testing
@testable import Lithe

@Suite("Collaboration runtime installation", .timeLimit(.minutes(1)))
struct CollaborationRuntimeTests {
    @Test func waitingViewsReceiveTheCompletedSwitchWithoutPolling() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let lease = try await fixture.store.acquire()
        let source = try fixture.package("update", version: "1.1.0")
        let queued = try await fixture.store.install(directory: source)
        let id = try #require(queued.pendingID)
        let stream = await fixture.store.updates()
        let switched = TestGate()
        let observer = Task {
            for await state in stream where state.selectedID == id && state.pendingID == nil && state.activeRuns == 0 {
                switched.open()
                break
            }
        }
        defer { observer.cancel() }
        await fixture.store.release(lease)
        #expect(await switched.waitUntilOpen())
        observer.cancel()
        await observer.value
    }
    @Test func aSecondStoreCannotSwitchOrRemoveAProcessPinnedRuntime() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let lease = try await fixture.store.acquire()
        let other = fixture.makeStore()
        await #expect(throws: PiRuntimeFailure.self) { try await other.select(id: "bundled") }
        await fixture.store.release(lease)
        #expect(try await other.select(id: "bundled").selectedID == "bundled")
    }
    @Test func installationCopiesWithoutChangingTheSourceOrBundle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let source = try fixture.package("update", version: "1.1.0")
        let before = try fixture.contents(source)
        let baseline = try fixture.contents(fixture.bundle)
        let installed = try await fixture.store.install(directory: source)
        #expect(installed.selectedID != "bundled")
        let lease = try await fixture.store.acquire()
        #expect(lease.directory != source)
        #expect(try fixture.contents(lease.directory) == before)
        await fixture.store.release(lease)
        #expect(try fixture.contents(source) == before)
        #expect(try fixture.contents(fixture.bundle) == baseline)
    }

    @Test func activeSessionsKeepTheirVersionUntilTheLastLeaseEndsAndRollbackPersists() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let first = try await fixture.store.acquire()
        let second = try await fixture.store.acquire()
        let source = try fixture.package("update", version: "1.1.0")
        let queued = try await fixture.store.install(directory: source)
        #expect(queued.selectedID == "bundled")
        #expect(queued.pendingID != nil)
        await fixture.store.release(first)
        #expect(try await fixture.store.status().selectedID == "bundled")
        await fixture.store.release(second)
        let applied = try await fixture.store.status()
        #expect(applied.selectedID == queued.pendingID)
        #expect(applied.pendingID == nil)
        let restarted = fixture.makeStore()
        #expect(try await restarted.status().selectedID == applied.selectedID)
        _ = try await restarted.select(id: "bundled")
        #expect(try await fixture.makeStore().status().selectedID == "bundled")
        let removed = try await restarted.remove(id: applied.selectedID)
        #expect(removed.versions.count == 1)
    }

    @Test func alteredPayloadIsRefusedAndReimportRepairsAnUnleasedVersion() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let source = try fixture.package("update", version: "1.1.0")
        let state = try await fixture.store.install(directory: source)
        let lease = try await fixture.store.acquire()
        try Data("corrupt".utf8).write(to: lease.directory.appendingPathComponent("src/main.mjs"))
        await #expect(throws: PiRuntimeFailure.self) { try await fixture.store.install(directory: source) }
        await fixture.store.release(lease)
        let damaged = try await fixture.store.status()
        #expect(damaged.versions.first(where: { $0.id == state.selectedID })?.available == false)
        await #expect(throws: PiAgentFailure.self) { try await fixture.store.acquire() }
        let repaired = try await fixture.store.install(directory: source)
        #expect(repaired.selectedID == state.selectedID)
        #expect(repaired.versions.first(where: { $0.id == state.selectedID })?.available == true)
        let recovered = try await fixture.store.acquire()
        await fixture.store.release(recovered)
    }

    @Test func aCorruptQueuedVersionCannotReplaceTheWorkingSelection() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let lease = try await fixture.store.acquire()
        let source = try fixture.package("update", version: "1.1.0")
        let queued = try await fixture.store.install(directory: source)
        let id = try #require(queued.pendingID)
        try Data("corrupt".utf8).write(to: fixture.storage.appendingPathComponent("Versions/\(id)/src/main.mjs"))
        await fixture.store.release(lease)
        let state = try await fixture.store.status()
        #expect(state.selectedID == "bundled")
        #expect(state.pendingID == nil)
        #expect(state.message != nil)
        _ = try await fixture.store.remove(id: id)
    }

    @Test func incompatibleMetadataAdditionalFilesAndSymlinksNeverInstall() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let incompatible: [[String: Any]] = [["protocolVersion": 2], ["architecture": "x64"], ["platform": "win32"]]
        for (index, change) in incompatible.enumerated() {
            let source = try fixture.package("invalid-\(index)", version: "1.1.0", overrides: change)
            await #expect(throws: PiAgentFailure.self) { try await fixture.store.install(directory: source) }
        }
        let source = try fixture.package("extra", version: "1.1.0")
        let extra = source.appendingPathComponent("extra")
        try Data("extra".utf8).write(to: extra)
        await #expect(throws: PiAgentFailure.self) { try await fixture.store.install(directory: source) }
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: source.appendingPathComponent("src/main.mjs"))
        await #expect(throws: PiAgentFailure.self) { try await fixture.store.install(directory: source) }
        #expect(try await fixture.store.status().versions.count == 1)
    }

    @Test func cancelledImportLeavesNoStagingAndCorruptPreferencesRemainRecoverable() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.clean() }
        let source = try fixture.package("update", version: "1.1.0")
        let gate = TestGate()
        let task = Task {
            guard await gate.waitUntilOpen() else { throw PiAgentFailure.timedOut }
            return try await fixture.store.install(directory: source)
        }
        defer { gate.open(); task.cancel() }
        task.cancel(); gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.path))
        try FileManager.default.createDirectory(at: fixture.storage, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: fixture.storage.appendingPathComponent("active.json"))
        let state = try await fixture.store.status()
        #expect(state.message != nil)
        let repaired = try await fixture.store.install(directory: source)
        #expect(try await fixture.makeStore().status().selectedID == repaired.selectedID)
    }
}

private struct RuntimeFixture: Sendable {
    let root: URL
    let bundle: URL
    let storage: URL
    let store: MacPiRuntimeStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-pi-runtime-\(UUID().uuidString)")
        bundle = root.appendingPathComponent("bundle")
        storage = root.appendingPathComponent("support")
        store = MacPiRuntimeStore(storageDirectory: storage, bundledDirectory: bundle, architecture: "arm64")
        do { _ = try package("bundle", version: "1.0.0") }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func makeStore() -> MacPiRuntimeStore { MacPiRuntimeStore(storageDirectory: storage, bundledDirectory: bundle, architecture: "arm64") }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func package(_ name: String, version: String, overrides: [String: Any] = [:]) throws -> URL {
        let directory = root.appendingPathComponent(name)
        let payload = ["src/main.mjs": "fixture-\(version)", "platform/macos.sb": "fixture-profile", "bin/node": "fixture-node",
                       "package.json": "{}", "package-lock.json": "{}", "node_modules/@earendil-works/pi-coding-agent/package.json": "{\"version\":\"1.2.0\"}"]
        var files: [String: [String: Any]] = [:]
        for (path, text) in payload {
            let file = directory.appendingPathComponent(path), bytes = Data(text.utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            files[path] = ["sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "bytes": bytes.count]
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("bin/node").path)
        var manifest: [String: Any] = ["schemaVersion": 1, "protocolVersion": 1, "version": version, "sdkVersion": "1.2.0", "nodeVersion": "24.1.0",
                                       "platform": "darwin", "architecture": "arm64", "files": files]
        manifest.merge(overrides) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: directory.appendingPathComponent("lithe-pi-runtime.json"))
        return directory
    }
    func contents(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let iterator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in iterator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
}
