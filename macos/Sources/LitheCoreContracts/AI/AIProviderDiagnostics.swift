import Foundation

/// Settings diagnostics use saved credentials and never send project contents.
public protocol AIProviderDiagnosing: Sendable {
    func models(for provider: AIProviderProfile) async throws -> [String]
    func testConnection(for provider: AIProviderProfile) async throws
}

public struct UnavailableAIProviderDiagnostics: AIProviderDiagnosing {
    public init() {}
    public func models(for provider: AIProviderProfile) async throws -> [String] {
        throw AIProviderDiagnosticError.unavailable
    }
    public func testConnection(for provider: AIProviderProfile) async throws {
        throw AIProviderDiagnosticError.unavailable
    }
}

/// Stable, credential-free diagnostics; upstream response bodies are never displayed.
public enum AIProviderDiagnosticError: LocalizedError, Equatable, Sendable {
    case unavailable, invalidEndpoint, missingKey, missingModel, modelListUnsupported
    case invalidResponse, tooManyModels, network, timedOut
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "AI provider diagnostics are unavailable.")
        case .invalidEndpoint: String(localized: "Check the API URL and the HTTP permission for this provider.")
        case .missingKey: String(localized: "Save an API key first. Imported providers read the key from their source configuration.")
        case .missingModel: String(localized: "Select or enter a model before testing the connection.")
        case .modelListUnsupported: String(localized: "This provider does not expose a model list. Enter the model manually, then test the connection.")
        case .invalidResponse: String(localized: "The provider returned an unexpected response. Check the API protocol and URL.")
        case .tooManyModels: String(localized: "The model list exceeds the supported size. Enter a model manually.")
        case .network: String(localized: "Could not reach the provider. Check the API URL and network connection.")
        case .timedOut: String(localized: "The provider did not respond in time. Check the connection and try again.")
        case .http(401): String(localized: "Authentication failed (401). Check this provider's key and authentication method; for an imported provider, check its source configuration.")
        case .http(403): String(localized: "Access denied (403). Check the account's API and model permissions.")
        case .http(404): String(localized: "API or model not found (404). Check the URL, protocol and model name.")
        case .http(429): String(localized: "The provider rejected the request (429). Check the quota or retry later.")
        case .http(let code): String(format: String(localized: "Provider request failed (%d). Check the API protocol and provider status."), code)
        }
    }
}
