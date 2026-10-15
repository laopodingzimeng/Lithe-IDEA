import Foundation
import LitheCoreContracts
import LitheAIAssistanceModule

/// Reuses the provider protocols, credentials and bounded HTTP request lifecycle.
struct CollaborationGenerationService: CollaborationGenerating {
    let service: CommitMessageGenerationService
    func generate(system: String, prompt: String, settings: CommitMessageAISettings) async throws -> String {
        do {
            return try await service.generateWorkflowText(system: system, prompt: prompt, settings: settings)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? CollaborationRequestFailure.timedOut : .network
        } catch let error as CommitMessageGenerationError {
            switch error {
            case .httpFailure(let status): throw CollaborationRequestFailure.http(status)
            case .noProviderConfigured, .invalidProvider, .insecureEndpoint, .missingAPIKey:
                throw CollaborationRequestFailure.configuration
            default: throw CollaborationRequestFailure.invalidResponse
            }
        } catch is DecodingError {
            throw CollaborationRequestFailure.invalidResponse
        } catch {
            throw CollaborationRequestFailure.network
        }
    }
}
