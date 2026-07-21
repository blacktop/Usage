import Foundation
import Synchronization

/// Fixture-replaying `HTTPTransport`.
///
/// Records every request so a request-construction test can assert on headers and URL, and replays
/// stubbed responses or failures per URL. An unstubbed URL fails rather than reaching the network.
public final class InMemoryHTTPTransport: HTTPTransport, Sendable {
    private struct State {
        var responses: [URL: [Result<HTTPResponse, UsageError>]] = [:]
        var requests: [HTTPRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Queues one response for `url`. Repeated calls replay in insertion order; the last queued
    /// entry repeats once the queue is drained.
    public func stub(_ url: URL, with response: HTTPResponse) {
        state.withLock { $0.responses[url, default: []].append(.success(response)) }
    }

    public func stub(_ url: URL, failingWith error: UsageError) {
        state.withLock { $0.responses[url, default: []].append(.failure(error)) }
    }

    public var recordedRequests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let outcome = state.withLock { state -> Result<HTTPResponse, UsageError> in
            state.requests.append(request)
            guard let queued = state.responses[request.url], let next = queued.first else {
                return .failure(.transportFailure())
            }
            if queued.count > 1 {
                state.responses[request.url] = Array(queued.dropFirst())
            }
            return next
        }
        return try outcome.get()
    }
}
