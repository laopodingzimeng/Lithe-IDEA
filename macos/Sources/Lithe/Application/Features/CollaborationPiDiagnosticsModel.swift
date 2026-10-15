import Combine
import Foundation
import LitheCoreContracts

@MainActor
final class CollaborationPiDiagnosticsModel: ObservableObject {
    enum State { case idle, loading, ready, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var provider: AIProviderProfile?
    private let diagnostics: CollaborationPiDiagnostics
    init(pi: any PiAgentRunning) { diagnostics = .init(runner: pi) }

    func bind(_ provider: AIProviderProfile?) {
        guard self.provider != provider else { return }
        self.provider = provider
        cancel()
    }
    @discardableResult
    func test(role: PiAgentRole, workspace: URL?) -> Task<Void, Never>? {
        guard task == nil, let provider, let workspace else { return nil }
        epoch = UUID(); let operation = epoch
        state = .loading; message = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == operation { self.task = nil } }
            do {
                try await self.diagnostics.test(provider: provider, role: role, workspace: workspace)
                try Task.checkCancellation()
                guard self.epoch == operation else { return }
                self.state = .ready
                self.message = role == .presentation ? "Pi 讲解格式测试通过" : "Pi 工具协议测试通过（未修改项目）"
            } catch {
                guard self.epoch == operation else { return }
                self.state = .failed
                self.message = (error as? LocalizedError)?.errorDescription ?? "模型未完成能力测试，请检查协议与工具支持。"
            }
        }
        return task
    }
    func cancel() {
        epoch = UUID(); let operation = epoch
        let pending = task
        pending?.cancel()
        message = nil
        guard let pending else { state = .idle; return }
        state = .loading
        task = Task { [weak self] in
            await pending.value
            guard let self, self.epoch == operation else { return }
            self.task = nil; self.state = .idle
        }
    }
    func shutdown() async { cancel(); await task?.value }
}
