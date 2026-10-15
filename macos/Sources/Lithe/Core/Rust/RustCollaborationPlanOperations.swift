import Foundation

struct RustCollaborationPlanOperations: CollaborationPlanOperating {
    let core: RustCoreBridge
    func transition(_ plan: CollaborationPlan, action: CollaborationAction) throws -> CollaborationPlan {
        struct Payload: Encodable {
            let plan: CollaborationPlan
            let expectedVersion: UInt64
            let action: CollaborationAction
        }
        let result: Result<CollaborationPlan, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "collaboration.transition",
            payload: Payload(plan: plan, expectedVersion: plan.version, action: action)
        )
        return try result.get()
    }
}

extension RustCollaborationPlanOperations {
    func prepare(_ plan: CollaborationPlan, files: [CollaborationFile], changes: [CollaborationChange]) throws -> CollaborationReceipt {
        struct Payload: Encodable {
            let plan: CollaborationPlan
            let expectedVersion: UInt64
            let stepId: String
            let files: [CollaborationFile]
            let changes: [CollaborationChange]
        }
        guard let step = plan.step else { throw CollaborationFailure.invalidState }
        let result: Result<CollaborationReceipt, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "collaboration.prepare", payload: Payload(plan: plan, expectedVersion: plan.version,
                stepId: step.id, files: files, changes: changes))
        return try result.get()
    }
    func reverse(_ receipt: CollaborationReceipt, files: [CollaborationFile]) throws -> CollaborationReceipt {
        struct Payload: Encodable { let receipt: CollaborationReceipt; let files: [CollaborationFile] }
        // Tool identity belongs to the host journal, not Core's strict v1 schema.
        var coreReceipt = receipt
        coreReceipt.operationId = nil
        let result: Result<CollaborationReceipt, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "collaboration.reverse", payload: Payload(receipt: coreReceipt, files: files))
        var inverse = try result.get()
        inverse.operationId = receipt.operationId
        return inverse
    }
}
