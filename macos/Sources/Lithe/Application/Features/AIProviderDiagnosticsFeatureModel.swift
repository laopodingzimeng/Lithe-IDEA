import Combine
import Foundation
import LitheCoreContracts

/// One settings page owns one operation; edits and navigation invalidate old results.
@MainActor
final class AIProviderDiagnosticsFeatureModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, failed }
    @Published private(set) var modelState: State = .idle
    @Published private(set) var connectionState: State = .idle
    @Published private(set) var models: [String] = []
    @Published private(set) var modelError: String?
    @Published private(set) var connectionError: String?
    private var provider: AIProviderProfile?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private let service: any AIProviderDiagnosing
    var busy: Bool { modelState == .loading || connectionState == .loading }

    init(service: any AIProviderDiagnosing) { self.service = service }

    func bind(_ provider: AIProviderProfile?) {
        guard self.provider != provider else { return }
        let previous = self.provider
        cancel()
        self.provider = provider
        // A model selection does not change the endpoint's catalog.
        var sameCatalog = previous
        if let provider { sameCatalog?.model = provider.model }
        if sameCatalog != provider { models = []; modelState = .idle; modelError = nil }
        connectionState = .idle; connectionError = nil
    }

    func credentialsChanged() {
        cancel()
        models = []; modelState = .idle; connectionState = .idle
        modelError = nil; connectionError = nil
    }

    @discardableResult
    func fetchModels() -> Task<Void, Never>? {
        guard !busy, let provider else { return nil }
        modelState = .loading; modelError = nil
        let token = UUID(); operation = token
        task = Task { [weak self, service] in
            do {
                let models = try await service.models(for: provider)
                try Task.checkCancellation()
                guard let self, self.operation == token else { return }
                self.models = models; self.modelState = .ready; self.task = nil
            } catch {
                guard let self, self.operation == token else { return }
                self.modelState = error is CancellationError ? .idle : .failed
                self.modelError = error is CancellationError ? nil : error.localizedDescription
                self.task = nil
            }
        }
        return task
    }

    @discardableResult
    func testConnection() -> Task<Void, Never>? {
        guard !busy, let provider else { return nil }
        connectionState = .loading; connectionError = nil
        let token = UUID(); operation = token
        task = Task { [weak self, service] in
            do {
                try await service.testConnection(for: provider)
                try Task.checkCancellation()
                guard let self, self.operation == token else { return }
                self.connectionState = .ready; self.task = nil
            } catch {
                guard let self, self.operation == token else { return }
                self.connectionState = error is CancellationError ? .idle : .failed
                self.connectionError = error is CancellationError ? nil : error.localizedDescription
                self.task = nil
            }
        }
        return task
    }

    func cancel() {
        operation = UUID(); task?.cancel(); task = nil
        if modelState == .loading { modelState = .idle }
        if connectionState == .loading { connectionState = .idle }
    }

    func shutdown() async {
        let pending = task
        cancel()
        await pending?.value
    }
}
