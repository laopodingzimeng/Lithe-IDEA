import Foundation

/// Data-only extension contract. Imported packages never carry executable code or authority.
struct CollaborationWorkflow: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let version: String
    let title: String
    let requirement: String
    let steps: [CollaborationStep]
    let prompts: [String: String]
    /// Optional, confirmed independent file paths within an AI step. This is
    /// scheduling metadata, never an additional write target or Core action.
    var independentFiles: [String: [String]]? = nil

    /// v2 retains original tasks; Core compiles them into human-accepted waves.
    var dependsOn: [String: [String]]? = nil

    func validate() throws {
        guard [1, 2].contains(schemaVersion), !id.isEmpty, id.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              !version.isEmpty, !title.isEmpty, !requirement.isEmpty,
              !steps.isEmpty, steps.count <= 100,
              Set(steps.map(\.id)).count == steps.count,
              prompts.keys.allSatisfy({ key in steps.contains { $0.id == key } }) else {
            throw CollaborationFailure.invalidPackage
        }
        guard schemaVersion == 1 ? dependsOn == nil : (dependsOn != nil && independentFiles == nil) else {
            throw CollaborationFailure.invalidPackage
        }
        for step in steps {
            guard !step.id.isEmpty, !step.title.isEmpty, !step.acceptance.isEmpty,
                  step.acceptance.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  step.questions.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  step.targets.count <= 100, step.decisions.isEmpty else { throw CollaborationFailure.invalidPackage }
            for target in step.targets {
                guard Self.isRelativePath(target.path),
                      target.kind == "file" || (target.kind == "javaMethod" && target.path.hasSuffix(".java") &&
                        !(target.typeName ?? "").isEmpty && !(target.signature ?? "").isEmpty) else {
                    throw CollaborationFailure.invalidPackage
                }
            }
        }
        for (id, paths) in independentFiles ?? [:] {
            guard let step = steps.first(where: { $0.id == id }), step.owner == .ai,
                  paths.count >= 2, paths.count <= 8, Set(paths).count == paths.count,
                  Set(paths) == Set(step.targets.map(\.path)) else { throw CollaborationFailure.invalidPackage }
        }
    }

    static func isRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\\") && !value.contains(":") && !value.contains("\0") &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }
    }
}

struct CollaborationStep: Codable, Identifiable, Sendable {
    enum Owner: String, Codable, Sendable { case human, ai }
    let id: String
    let title: String
    let owner: Owner
    let targets: [CollaborationTarget]
    let acceptance: [String]
    let questions: [String]
    var decisions: [String] = []
}

struct CollaborationTarget: Codable, Sendable, Equatable {
    let kind: String
    let path: String
    var typeName: String? = nil
    var signature: String? = nil
}

struct CollaborationPlan: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case draft, ready, aiWorking, humanWorking, checking, review, complete
        var title: String {
            switch self {
            case .draft: "确认分工"
            case .ready: "准备开始"
            case .aiWorking: "配套工作"
            case .humanWorking: "你来编写"
            case .checking: "交接检查"
            case .review: "等待验收"
            case .complete: "已完成"
            }
        }
    }
    let id: String
    var version: UInt64
    let requirement: String
    var steps: [CollaborationStep]
    var currentStep: Int
    var phase: Phase
    var paused: Bool
    var step: CollaborationStep? { steps.indices.contains(currentStep) ? steps[currentStep] : nil }
}

struct CollaborationAction: Encodable, Sendable {
    let kind: String
    var answers: [String]? = nil
}

struct CollaborationSchedule: Codable, Sendable {
    let steps: [CollaborationStep]
    let groups: [String: [String]]
}

protocol CollaborationPlanOperating: Sendable {
    func schedule(_ workflow: CollaborationWorkflow) throws -> CollaborationSchedule
    func transition(_ plan: CollaborationPlan, action: CollaborationAction) throws -> CollaborationPlan
    func prepare(_ plan: CollaborationPlan, files: [CollaborationFile], changes: [CollaborationChange]) throws -> CollaborationReceipt
    func previewSuggestion(_ plan: CollaborationPlan, files: [CollaborationFile], change: CollaborationChange) throws -> CollaborationReceipt
    func reverse(_ receipt: CollaborationReceipt, files: [CollaborationFile]) throws -> CollaborationReceipt
}

extension CollaborationPlanOperating {
    func schedule(_ workflow: CollaborationWorkflow) throws -> CollaborationSchedule {
        guard workflow.schemaVersion == 1 else { throw CollaborationFailure.unavailable }
        return CollaborationSchedule(steps: workflow.steps, groups: [:])
    }
    func prepare(_ plan: CollaborationPlan, files: [CollaborationFile], changes: [CollaborationChange]) throws -> CollaborationReceipt { throw CollaborationFailure.unavailable }
    func previewSuggestion(_ plan: CollaborationPlan, files: [CollaborationFile], change: CollaborationChange) throws -> CollaborationReceipt { throw CollaborationFailure.unavailable }
    func reverse(_ receipt: CollaborationReceipt, files: [CollaborationFile]) throws -> CollaborationReceipt { throw CollaborationFailure.unavailable }
}

struct UnavailableCollaborationPlanOperations: CollaborationPlanOperating {
    func transition(_ plan: CollaborationPlan, action: CollaborationAction) throws -> CollaborationPlan {
        throw CollaborationFailure.unavailable
    }
}

enum CollaborationFailure: LocalizedError {
    case invalidPackage, unavailable, activePlan, missingProject, missingEvidence, invalidState
    var errorDescription: String? {
        switch self {
        case .invalidPackage: "工作流包无效或版本不兼容，请使用 schemaVersion 1 或 2 的桌面工作流包。"
        case .unavailable: "当前宿主尚未提供协作计划能力。"
        case .activePlan: "当前计划尚未结束。请先完成或明确结束当前计划，再载入新的工作流。"
        case .missingProject: "请先打开项目。"
        case .missingEvidence: "请记录实际修改、检查命令和结果，再提交验收。"
        case .invalidState: "协作状态不完整，无法安全恢复。原记录已保留。"
        }
    }
}
