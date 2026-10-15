import Foundation
import LitheCoreContracts

/// Role bindings reference existing provider profiles/Keychain identities. Model
/// overrides are per role; changing one role never changes commit-message AI.
struct CollaborationModelSettings: Codable, Equatable, Sendable {
    var developmentProviderID: UUID? = nil
    var developmentModel = ""
    var presentationProviderID: UUID? = nil
    var presentationModel = ""
    var narrationEnabled = true
    var maximumParallelTasks = 3
    var developmentTimeoutSeconds = 600

    func provider(for role: PiAgentRole, in settings: CommitMessageAISettings) -> AIProviderProfile? {
        let presentation = role == .presentation
        let selected = presentation ? presentationProviderID : developmentProviderID
        let fallback = presentation ? developmentProviderID ?? settings.activeProviderID : settings.activeProviderID
        guard let id = selected ?? fallback, var provider = settings.providers.first(where: { $0.id == id }) else { return nil }
        let model = (presentation ? presentationModel : developmentModel).trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { provider.model = model }
        return provider
    }
    func settings(for role: PiAgentRole, in settings: CommitMessageAISettings) -> CommitMessageAISettings {
        var result = settings
        if let provider = provider(for: role, in: settings) { result.providers = [provider]; result.activeProviderID = provider.id }
        else { result.providers = []; result.activeProviderID = nil }
        return result
    }
}
