import Foundation
import LitheCoreContracts
import LitheAIAssistanceModule

/// Reuses the provider protocols, credentials and bounded HTTP request lifecycle.
struct CollaborationGenerationService: CollaborationGenerating {
    let service: CommitMessageGenerationService
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        try await service.generateWorkflowText(system: system, prompt: prompt, settings: settings)
    }
}
