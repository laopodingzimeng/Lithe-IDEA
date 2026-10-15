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
    var developmentOutputTokens = 8192
    var developmentTokenBudget = 200_000
    var presentationOutputTokens = 2048
    var presentationTokenBudget = 32_000
    var automaticNarrationRequests = 8

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

// Defaults keep existing role bindings readable when new budgets are introduced.
extension CollaborationModelSettings {
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        developmentProviderID = try value.decodeIfPresent(UUID.self, forKey: .developmentProviderID)
        developmentModel = try value.decodeIfPresent(String.self, forKey: .developmentModel) ?? ""
        presentationProviderID = try value.decodeIfPresent(UUID.self, forKey: .presentationProviderID)
        presentationModel = try value.decodeIfPresent(String.self, forKey: .presentationModel) ?? ""
        narrationEnabled = try value.decodeIfPresent(Bool.self, forKey: .narrationEnabled) ?? true
        maximumParallelTasks = min(8, max(1, try value.decodeIfPresent(Int.self, forKey: .maximumParallelTasks) ?? 3))
        developmentTimeoutSeconds = min(3600, max(30, try value.decodeIfPresent(Int.self, forKey: .developmentTimeoutSeconds) ?? 600))
        developmentOutputTokens = min(64_000, max(128, try value.decodeIfPresent(Int.self, forKey: .developmentOutputTokens) ?? 8192))
        developmentTokenBudget = min(2_000_000, max(128, try value.decodeIfPresent(Int.self, forKey: .developmentTokenBudget) ?? 200_000))
        presentationOutputTokens = min(64_000, max(128, try value.decodeIfPresent(Int.self, forKey: .presentationOutputTokens) ?? 2048))
        presentationTokenBudget = min(2_000_000, max(128, try value.decodeIfPresent(Int.self, forKey: .presentationTokenBudget) ?? 32_000))
        automaticNarrationRequests = min(100, max(0, try value.decodeIfPresent(Int.self, forKey: .automaticNarrationRequests) ?? 8))
    }
}
