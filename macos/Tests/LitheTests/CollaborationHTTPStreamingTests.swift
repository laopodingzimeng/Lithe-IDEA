import Foundation
import Network
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Collaboration HTTP streaming", .timeLimit(.minutes(1)))
struct CollaborationHTTPStreamingTests {
    @Test func chunkedHTTPPublishesBeforeResponseCompletes() async throws {
        let server = try CollaborationLoopbackServer()
        defer { server.close() }
        #expect(await server.ready.waitUntilOpen())
        let port = try #require(server.port)
        let received = TestGate()
        let request = AIHTTPRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/")),
            headers: [:], body: Data(), timeout: 5, allowsInsecureHTTP: true,
            onBody: { if !$0.isEmpty { received.open() } })
        let task = Task { try await MacURLSessionTransport().send(request) }
        defer { task.cancel() }
        #expect(await received.waitUntilOpen(), "Native HTTP must publish a chunk before the terminal chunk is sent")
        server.finish()
        let response = try await task.value
        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "data: first\n\n")
    }

    @Test func cancellingAnOpenHTTPStreamReleasesTheRequest() async throws {
        let server = try CollaborationLoopbackServer()
        defer { server.close() }
        #expect(await server.ready.waitUntilOpen())
        let port = try #require(server.port)
        let received = TestGate()
        let request = AIHTTPRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/")),
            headers: [:], body: Data(), timeout: 5, allowsInsecureHTTP: true,
            onBody: { _ in received.open() })
        let task = Task { try await MacURLSessionTransport().send(request) }
        defer { task.cancel() }
        #expect(await received.waitUntilOpen())
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled stream returned success") }
        catch { #expect(error is CancellationError) }
    }
}

/// Only loopback, an ephemeral port, and bounded request deadlines. The test
/// explicitly controls EOF; no timing delay is used to infer partial delivery.
private final class CollaborationLoopbackServer: @unchecked Sendable {
    let ready = TestGate()
    private let lock = NSLock()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "collaboration.fixture.http")
    private var connection: NWConnection?
    private var actualPort: UInt16?
    var port: UInt16? { lock.withLock { actualPort } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.lock.withLock { self.actualPort = self.listener.port?.rawValue }
                self.ready.open()
            } else if case .failed = state { self.ready.open() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connection = connection }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let body = "data: first\n\n"
                let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/event-stream\r\n\r\n"
                    + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                })
            }
        }
        listener.start(queue: queue)
    }
    func finish() {
        let connection = lock.withLock { self.connection }
        connection?.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
    }
    func close() {
        listener.cancel()
        lock.withLock { connection?.cancel(); connection = nil }
    }
}
