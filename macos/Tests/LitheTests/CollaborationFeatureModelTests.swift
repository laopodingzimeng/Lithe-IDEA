import Foundation
import Testing
@testable import Lithe

@Suite("Native collaboration workflows")
@MainActor
struct CollaborationFeatureModelTests {
    private let workspace = URL(fileURLWithPath: "/fixture/project")
    private func model(_ store: CollaborationMemoryStore = CollaborationMemoryStore()) -> CollaborationFeatureModel {
        CollaborationFeatureModel(operations: RustCollaborationPlanOperations(core: RustCoreBridge()),
            store: store, files: UnavailableFileStorage())
    }
    private func package(version: String = "1.0.0", path: String = "src/Order.java") throws -> Data {
        try JSONEncoder().encode(CollaborationWorkflow(schemaVersion: 1, id: "order", version: version,
            title: "订单规则", requirement: "计算金额", steps: [
                CollaborationStep(id: "business", title: "编写核心逻辑", owner: .human,
                    targets: [.init(kind: "file", path: path)], acceptance: ["拒绝负数"], questions: ["负数如何处理？"])
            ], prompts: ["business": "只审查边界条件"]))
    }

    @Test func importedPackageCannotReplaceAnActivePlan() throws {
        let feature = model(); feature.bind(workspace: workspace)
        feature.importWorkflow(data: try package())
        let id = feature.plan?.id
        feature.importWorkflow(data: try package(version: "2.0.0"))
        #expect(feature.plan?.id == id)
        #expect(feature.workflow?.version == "1.0.0")
        #expect(feature.error != nil)
        feature.discard(); feature.importWorkflow(data: try package(version: "2.0.0"))
        #expect(feature.workflow?.version == "2.0.0")
    }

    @Test func humanHandoffNeedsEvidenceAndExplicitAcceptance() throws {
        let feature = model(); feature.bind(workspace: workspace)
        feature.importWorkflow(data: try package())
        feature.perform("confirm"); feature.perform("start")
        #expect(feature.plan?.phase == .ready)
        feature.answers = ["抛出异常"]; feature.perform("resolveQuestions")
        #expect(feature.currentPrompt.contains("抛出异常"))
        feature.perform("start"); feature.perform("handoff"); feature.perform("workFinished")
        #expect(feature.plan?.phase == .checking)
        feature.resultText = "已核对负数分支；测试由开发者执行。"
        feature.perform("pause")
        #expect(feature.resultText == "已核对负数分支；测试由开发者执行。")
        feature.perform("resume")
        // Resuming a checking phase returns to the human before another handoff.
        feature.perform("handoff")
        feature.perform("workFinished")
        #expect(feature.plan?.phase == .review)
        feature.perform("accept")
        #expect(feature.plan?.phase == .complete)
    }

    @Test func restoredWorkNeverStartsAutomaticallyAndProjectsAreIsolated() throws {
        let store = CollaborationMemoryStore(), first = model(store)
        first.bind(workspace: workspace); first.importWorkflow(data: try package())
        first.perform("confirm")
        let restored = model(store); restored.bind(workspace: workspace)
        #expect(restored.plan?.paused == true)
        #expect(restored.plan?.id == first.plan?.id)
        restored.bind(workspace: URL(fileURLWithPath: "/fixture/other"))
        #expect(restored.plan == nil)
        restored.bind(workspace: workspace)
        #expect(restored.plan?.id == first.plan?.id)
    }

    @Test func invalidPathsAndOversizedPackagesDoNotCreatePlans() throws {
        let feature = model(); feature.bind(workspace: workspace)
        for path in ["../secret", "/outside", "src/../secret", ".git/config", "C:\\secret"] {
            feature.importWorkflow(data: try package(path: path))
            #expect(feature.plan == nil)
            #expect(feature.error != nil)
        }
        feature.importWorkflow(data: Data(repeating: 65, count: 1_048_577))
        #expect(feature.plan == nil)
    }

    @Test func brokenRecoveryIsPreservedUntilExplicitDiscard() throws {
        let store = CollaborationMemoryStore(), feature = model(store)
        let key = "collaboration.native.v1." + workspace.path
        let corrupt = Data("not-json".utf8); store.set(corrupt, forKey: key)
        feature.bind(workspace: workspace)
        feature.importWorkflow(data: try package())
        #expect(feature.plan == nil)
        #expect(store.data(forKey: key) == corrupt)
        feature.discard(); feature.importWorkflow(data: try package())
        #expect(feature.plan?.phase == .draft)
    }

    @Test func invalidTransitionsDoNotChangePersistedState() throws {
        let store = CollaborationMemoryStore(), feature = model(store)
        feature.bind(workspace: workspace); feature.importWorkflow(data: try package())
        let key = "collaboration.native.v1." + workspace.path
        let before = store.data(forKey: key)
        feature.perform("accept")
        #expect(feature.plan?.phase == .draft)
        #expect(store.data(forKey: key) == before)
    }
}

private final class CollaborationMemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
