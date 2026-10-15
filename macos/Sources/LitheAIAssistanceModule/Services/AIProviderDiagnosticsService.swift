import Foundation
import LitheCoreContracts

/// Reuses the existing provider transport and protocol encoders. Lists stay in memory.
public struct AIProviderDiagnosticsService: AIProviderDiagnosing {
    private let transport: any AIHTTPTransport
    private let credentials: any AIProviderCredentialResolver

    public init(transport: any AIHTTPTransport, credentials: any AIProviderCredentialResolver) {
        self.transport = transport
        self.credentials = credentials
    }

    public func models(for provider: AIProviderProfile) async throws -> [String] {
        do {
            let base = try validatedEndpoint(provider)
            let headers = requestHeaders(provider, key: try validatedKey(provider))
            let endpoint = catalogEndpoint(base, protocol: provider.apiProtocol)
            var models = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            // Anthropic paginates model lists; never silently present the first page as complete.
            for _ in 0..<20 {
                try Task.checkCancellation()
                var url = endpoint
                if let cursor {
                    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
                    guard let next = components.url else { throw AIProviderDiagnosticError.invalidResponse }
                    url = next
                }
                let response = try await transport.send(AIHTTPRequest(url: url, headers: headers,
                    body: Data(), timeout: 15, allowsInsecureHTTP: provider.allowsInsecureHTTP, method: .get))
                try Task.checkCancellation()
                if [404, 405, 501].contains(response.statusCode) { throw AIProviderDiagnosticError.modelListUnsupported }
                guard (200..<300).contains(response.statusCode) else { throw AIProviderDiagnosticError.http(response.statusCode) }
                guard response.body.count <= 1_048_576 else { throw AIProviderDiagnosticError.tooManyModels }
                guard let page = try? JSONDecoder().decode(ModelPage.self, from: response.body) else {
                    throw AIProviderDiagnosticError.invalidResponse
                }
                guard page.data.count <= 2_000 else { throw AIProviderDiagnosticError.tooManyModels }
                for model in page.data {
                    guard Self.validID(model.id) else { throw AIProviderDiagnosticError.invalidResponse }
                    models.insert(model.id)
                }
                guard models.count <= 2_000 else { throw AIProviderDiagnosticError.tooManyModels }
                guard page.hasMore == true else { return models.sorted() }
                guard provider.apiProtocol == .anthropicMessages, let next = page.lastID,
                      Self.validID(next), cursors.insert(next).inserted else { throw AIProviderDiagnosticError.invalidResponse }
                cursor = next
            }
            throw AIProviderDiagnosticError.tooManyModels
        } catch { throw Self.diagnostic(error) }
    }

    public func testConnection(for provider: AIProviderProfile) async throws {
        do {
            _ = try validatedEndpoint(provider)
            let key = try validatedKey(provider)
            guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderDiagnosticError.missingModel
            }
            try await CommitMessageGenerationService(transport: transport, credentialResolver: CredentialSnapshot(key: key))
                .testConnection(provider: provider)
            try Task.checkCancellation()
        } catch { throw Self.diagnostic(error) }
    }

    private func validatedEndpoint(_ provider: AIProviderProfile) throws -> URL {
        guard let url = provider.endpointURL, let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && provider.allowsInsecureHTTP) else {
            throw AIProviderDiagnosticError.invalidEndpoint
        }
        return url
    }

    private func validatedKey(_ provider: AIProviderProfile) throws -> String {
        let key = credentials.readAPIKey(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.contains("\r"), !key.contains("\n"), !provider.requiresAPIKey || !key.isEmpty else {
            throw AIProviderDiagnosticError.missingKey
        }
        return key
    }

    private func requestHeaders(_ provider: AIProviderProfile, key: String) -> [String: String] {
        var headers = ["Accept": "application/json"]
        if !key.isEmpty {
            headers[provider.authentication == .apiKey ? "x-api-key" : "Authorization"] =
                provider.authentication == .apiKey ? key : "Bearer \(key)"
        }
        if provider.apiProtocol == .anthropicMessages { headers["anthropic-version"] = "2023-06-01" }
        return headers
    }

    private func catalogEndpoint(_ base: URL, protocol apiProtocol: CommitMessageAPIProtocol) -> URL {
        var result = base
        let parts = base.path.split(separator: "/").map(String.init)
        if parts.suffix(2) == ["chat", "completions"] {
            result.deleteLastPathComponent(); result.deleteLastPathComponent()
        } else if let last = parts.last, ["responses", "messages", "models"].contains(last) {
            result.deleteLastPathComponent()
        }
        if apiProtocol == .anthropicMessages && result.lastPathComponent != "v1" {
            result.appendPathComponent("v1")
        }
        return result.appendingPathComponent("models")
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            value.rangeOfCharacter(from: .controlCharacters) == nil &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func diagnostic(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? AIProviderDiagnosticError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return CancellationError() }
            return error.code == .timedOut ? AIProviderDiagnosticError.timedOut : AIProviderDiagnosticError.network
        }
        if let error = error as? CommitMessageGenerationError {
            switch error {
            case .httpFailure(let status): return AIProviderDiagnosticError.http(status)
            case .missingAPIKey: return AIProviderDiagnosticError.missingKey
            case .invalidProvider, .insecureEndpoint: return AIProviderDiagnosticError.invalidEndpoint
            default: return AIProviderDiagnosticError.invalidResponse
            }
        }
        return AIProviderDiagnosticError.network
    }

    private struct ModelPage: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
        let hasMore: Bool?
        let lastID: String?
        enum CodingKeys: String, CodingKey { case data; case hasMore = "has_more"; case lastID = "last_id" }
    }

    private struct CredentialSnapshot: AIProviderCredentialResolver {
        let key: String
        func readAPIKey(for provider: AIProviderProfile) -> String? { key }
    }
}
