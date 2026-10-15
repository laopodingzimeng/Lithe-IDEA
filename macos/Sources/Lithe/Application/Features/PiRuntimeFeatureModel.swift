import Combine
import Foundation

@MainActor
final class PiRuntimeFeatureModel: ObservableObject {
    @Published private(set) var snapshot: PiRuntimeStatus?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service: any PiRuntimeManaging
    private var task: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    init(service: any PiRuntimeManaging) {
        self.service = service
        observation = Task { [weak self] in
            for await snapshot in await service.updates() {
                guard !Task.isCancelled else { break }
                self?.snapshot = snapshot
            }
        }
    }
    func refresh() { let service = service; perform { try await service.status() } }
    func install(_ directory: URL) { let service = service; perform { try await service.install(directory: directory) } }
    func select(_ id: String) { let service = service; perform { try await service.select(id: id) } }
    func remove(_ id: String) { let service = service; perform { try await service.remove(id: id) } }
    private func perform(_ operation: @escaping @Sendable () async throws -> PiRuntimeStatus) {
        guard task == nil else { return }
        busy = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            do { self.snapshot = try await operation() }
            catch {
                if !(error is CancellationError) {
                    self.error = (error as? PiRuntimeFailure)?.errorDescription ??
                        (error as? PiAgentFailure)?.errorDescription ?? "运行包操作未完成，请检查目录、版本兼容性和读写权限。"
                }
            }
        }
    }
    func shutdown() async {
        task?.cancel(); observation?.cancel()
        await task?.value; await observation?.value
        observation = nil
    }
}
