import Foundation
import LitheAIAssistanceModule
import LitheCoreContracts
import Testing

@Suite("AI provider diagnostics", .timeLimit(.minutes(1)))
struct AIProviderDiagnosticsTests {
    private func provider(_ api: CommitMessageAPIProtocol = .responses, endpoint: String = "https://fixture.test/proxy/v1/responses") -> AIProviderProfile {
        AIProviderProfile(name: "Fixture", endpoint: endpoint, model: "fixture-model", apiProtocol: api)
    }
    private func service(_ transport: ProviderScriptTransport, key: String? = "fixture-key") -> AIProviderDiagnosticsService {
        .init(transport: transport, credentials: ProviderTestCredentials(key: key))
    }

    @Test func modelDiscoveryDoesNotRequireAModelAndPreservesGatewayPrefix() async throws {
        let transport = ProviderScriptTransport([.init(statusCode: 200,
            body: Data(#"{"data":[{"id":"z"},{"id":"a"},{"id":"z"}]}"#.utf8))])
        var profile = provider(.chatCompletions, endpoint: "https://fixture.test/gateway/v1/chat/completions/")
        profile.model = ""
        #expect(try await service(transport).models(for: profile) == ["a", "z"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://fixture.test/gateway/v1/models")
        #expect(request.body.isEmpty)
        #expect(request.headers["Authorization"] == "Bearer fixture-key")
    }

    @Test func anthropicCatalogFollowsBoundedPagesWithAPIKeyAuthentication() async throws {
        let transport = ProviderScriptTransport([
            .init(statusCode: 200, body: Data(#"{"data":[{"id":"model-a"}],"has_more":true,"last_id":"model-a"}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"data":[{"id":"model-b"}],"has_more":false}"#.utf8))
        ])
        let result = try await service(transport).models(for: provider(.anthropicMessages, endpoint: "https://fixture.test"))
        #expect(result == ["model-a", "model-b"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url.path == "/v1/models")
        #expect(requests.last?.url.query == "after_id=model-a")
        #expect(requests.first?.headers["x-api-key"] == "fixture-key")
        #expect(requests.first?.headers["Authorization"] == nil)
        #expect(requests.first?.headers["anthropic-version"] == "2023-06-01")
    }

    @Test func loopingCatalogPaginationIsRejected() async throws {
        let page = AIHTTPResponse(statusCode: 200,
            body: Data(#"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"#.utf8))
        let transport = ProviderScriptTransport([page, page])
        await #expect(throws: AIProviderDiagnosticError.invalidResponse) {
            try await service(transport).models(for: provider(.anthropicMessages, endpoint: "https://fixture.test/v1/messages"))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func unsupportedCatalogDoesNotPreventARealModelProbe() async throws {
        let transport = ProviderScriptTransport([
            .init(statusCode: 404, body: Data()),
            .init(statusCode: 200, body: Data(#"{"output_text":"OK"}"#.utf8))
        ])
        await #expect(throws: AIProviderDiagnosticError.modelListUnsupported) {
            try await service(transport).models(for: provider())
        }
        try await service(transport).testConnection(for: provider())
        let request = try #require(await transport.requests.last)
        #expect(request.method == .post)
        #expect(request.url.path == "/proxy/v1/responses")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "fixture-model")
        #expect(body["reasoning"] == nil)
        #expect(body["max_output_tokens"] as? Int == 1024)
    }

    @Test(arguments: CommitMessageAPIProtocol.allCases)
    func probesUseTheSelectedProtocolAndRequireAnActualModelResponse(_ api: CommitMessageAPIProtocol) async throws {
        let body: String
        switch api {
        case .responses: body = #"{"output_text":"OK"}"#
        case .chatCompletions: body = #"{"choices":[{"message":{"content":"OK"}}]}"#
        case .anthropicMessages: body = #"{"content":[{"type":"text","text":"OK"}]}"#
        }
        let transport = ProviderScriptTransport([.init(statusCode: 200, body: Data(body.utf8))])
        try await service(transport).testConnection(for: provider(api, endpoint: "https://fixture.test/v1"))
        let request = try #require(await transport.requests.first)
        #expect(request.url.path == "/v1/" + api.endpointSuffix)
        #expect(request.timeout == 45)
        let empty = ProviderScriptTransport([.init(statusCode: 200, body: Data(#"{"data":[]}"#.utf8))])
        await #expect(throws: AIProviderDiagnosticError.invalidResponse) {
            try await service(empty).testConnection(for: provider(api, endpoint: "https://fixture.test/v1"))
        }
    }

    @Test func authenticationFailureNeverDisplaysProviderBodyOrKey() async throws {
        let transport = ProviderScriptTransport([.init(statusCode: 401, body: Data("sensitive-provider-body".utf8))])
        await #expect(throws: AIProviderDiagnosticError.http(401)) {
            try await service(transport).testConnection(for: provider())
        }
        let message = AIProviderDiagnosticError.http(401).localizedDescription
        #expect(message.contains("401"))
        #expect(!message.contains("sensitive-provider-body"))
        #expect(!message.contains("fixture-key"))
    }

    @Test func invalidEndpointAndMissingKeyNeverReachTheNetwork() async throws {
        let transport = ProviderScriptTransport([])
        for endpoint in ["https://user:pass@fixture.test/v1", "https://fixture.test/v1?key=secret", "http://fixture.test/v1"] {
            await #expect(throws: AIProviderDiagnosticError.invalidEndpoint) {
                try await service(transport).models(for: provider(endpoint: endpoint))
            }
        }
        await #expect(throws: AIProviderDiagnosticError.missingKey) {
            try await service(transport, key: nil).models(for: provider())
        }
        #expect(await transport.requests.isEmpty)
    }
}

private struct ProviderTestCredentials: AIProviderCredentialResolver {
    let key: String?
    func readAPIKey(for provider: AIProviderProfile) -> String? { key }
}

private actor ProviderScriptTransport: AIHTTPTransport {
    private var responses: [AIHTTPResponse]
    private(set) var requests: [AIHTTPRequest] = []
    init(_ responses: [AIHTTPResponse]) { self.responses = responses }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIProviderDiagnosticError.network }
        return responses.removeFirst()
    }
}
