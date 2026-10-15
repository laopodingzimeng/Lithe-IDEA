import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
@Suite("AI provider settings lifecycle", .timeLimit(.minutes(1)))
struct AIProviderDiagnosticsFeatureTests {
    private func provider(_ name: String) -> AIProviderProfile {
        .init(name: name, endpoint: "https://fixture.test/v1", model: name, apiProtocol: .responses)
    }

    @Test func switchingProviderDiscardsALateCatalogFromThePreviousSelection() async throws {
        let service = ControlledProviderCatalog()
        let feature = AIProviderDiagnosticsFeatureModel(service: service)
        defer { feature.cancel() }
        let first = provider("first"), second = provider("second")
        var started = service.started.makeAsyncIterator()
        feature.bind(first)
        let old = try #require(feature.fetchModels())
        #expect(await started.next() == first.id)
        feature.bind(second)
        let current = try #require(feature.fetchModels())
        #expect(await started.next() == second.id)
        await service.release(second.id, models: ["second-model"])
        await current.value
        // Deliberately return after cancellation to exercise stale-result rejection.
        await service.release(first.id, models: ["wrong-model"])
        await old.value
        #expect(feature.models == ["second-model"])
        #expect(feature.modelState == .ready)
        #expect(!feature.busy)
    }

    @Test func modelSelectionPreservesCatalogButInvalidatesConnectionSuccess() async throws {
        let service = ImmediateProviderDiagnostics()
        let feature = AIProviderDiagnosticsFeatureModel(service: service)
        defer { feature.cancel() }
        var profile = provider("first")
        feature.bind(profile)
        await feature.fetchModels()?.value
        #expect(feature.connectionState == .idle, "Listing models is not a generation test")
        await feature.testConnection()?.value
        #expect(feature.connectionState == .ready)
        profile.model = "second"
        feature.bind(profile)
        #expect(feature.models == ["first", "second"])
        #expect(feature.connectionState == .idle)
        feature.credentialsChanged()
        #expect(feature.models.isEmpty)
        #expect(feature.modelState == .idle)
    }

    @Test func cancellationEndsLoadingAndCannotApplyALateResult() async throws {
        let service = ControlledProviderCatalog()
        let feature = AIProviderDiagnosticsFeatureModel(service: service)
        defer { feature.cancel() }
        let profile = provider("first")
        var started = service.started.makeAsyncIterator()
        feature.bind(profile)
        let operation = try #require(feature.fetchModels())
        #expect(await started.next() == profile.id)
        feature.cancel()
        #expect(!feature.busy)
        await service.release(profile.id, models: ["cancelled-model"])
        await operation.value
        #expect(feature.models.isEmpty)
        #expect(feature.modelState == .idle)
    }
}

private struct ImmediateProviderDiagnostics: AIProviderDiagnosing {
    func models(for provider: AIProviderProfile) async throws -> [String] { ["first", "second"] }
    func testConnection(for provider: AIProviderProfile) async throws {}
}

private actor ControlledProviderCatalog: AIProviderDiagnosing {
    let started: AsyncStream<UUID>
    private let events: AsyncStream<UUID>.Continuation
    private var pending: [UUID: CheckedContinuation<[String], Never>] = [:]

    init() {
        let stream = AsyncStream<UUID>.makeStream()
        started = stream.stream; events = stream.continuation
    }
    func models(for provider: AIProviderProfile) async throws -> [String] {
        await withCheckedContinuation { continuation in
            pending[provider.id] = continuation
            events.yield(provider.id)
        }
    }
    func testConnection(for provider: AIProviderProfile) async throws {}
    func release(_ id: UUID, models: [String]) { pending.removeValue(forKey: id)?.resume(returning: models) }
    deinit { events.finish() }
}
