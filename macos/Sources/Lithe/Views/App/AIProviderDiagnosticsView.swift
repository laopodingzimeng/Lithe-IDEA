import SwiftUI
import LitheCoreContracts

struct AIProviderDiagnosticsView: View {
    @ObservedObject var feature: AIProviderDiagnosticsFeatureModel
    let provider: AIProviderProfile
    let hasUnsavedKey: Bool
    let configurationManaged: Bool
    let selectModel: (String) -> Void

    private var options: [String] {
        [provider.model] + feature.models.filter { $0 != provider.model }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Fetch models") { feature.fetchModels() }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .disabled(feature.busy || hasUnsavedKey)
                Button("Test connection") { feature.testConnection() }
                    .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.settingsPrimaryAction, restingOpacity: 1))
                    .disabled(feature.busy || hasUnsavedKey || provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if feature.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { feature.cancel() }.buttonStyle(LitheSecondaryButtonStyle())
                }
            }
            if hasUnsavedKey {
                Text("Save the edited key before fetching models or testing.")
                    .foregroundStyle(LitheTheme.warning)
            }
            if !feature.models.isEmpty {
                LitheSettingsSelect(selection: Binding(get: { provider.model }, set: selectModel),
                    options: options, width: 320, accessibilityLabel: "Available models",
                    title: { $0.isEmpty ? String(localized: "Select a model") : $0 }, localizesTitles: false,
                    searchPrompt: "Search models")
                    .disabled(configurationManaged || feature.busy || hasUnsavedKey)
                Text(String(format: String(localized: "%d models available. You can also enter a model manually."), feature.models.count))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if feature.modelState == .ready {
                Text("The provider returned no models. Enter a model manually to test it.")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            if let error = feature.modelError { Text(LocalizedStringKey(error)).foregroundStyle(LitheTheme.warning).textSelection(.enabled) }
            if let error = feature.connectionError { Text(LocalizedStringKey(error)).foregroundStyle(LitheTheme.warning).textSelection(.enabled) }
            if feature.connectionState == .ready {
                Label("Connection successful. The selected model returned a response.", systemImage: "checkmark.circle")
                    .foregroundStyle(LitheTheme.primaryText)
            }
            Text("Testing sends a short message to the selected model and may incur API usage. Project code is not sent.")
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .onAppear {
            feature.bind(provider)
            fetchIfConfigured()
        }
        .onChange(of: provider) { next in
            let changedSelection = featureProviderID != next.id
            feature.bind(next)
            featureProviderID = next.id
            if changedSelection { fetchIfConfigured() }
        }
        .onChange(of: hasUnsavedKey) { edited in
            feature.credentialsChanged()
            if !edited { fetchIfConfigured() }
        }
        .onDisappear { feature.cancel() }
    }

    @State private var featureProviderID: UUID?

    private func fetchIfConfigured() {
        featureProviderID = provider.id
        guard !hasUnsavedKey, provider.endpointURL != nil, feature.modelState == .idle else { return }
        feature.fetchModels()
    }
}
