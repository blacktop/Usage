import Foundation

/// The production `HTTPTransport`.
///
/// The session is ephemeral and cookie-free on purpose. Two of the three endpoints Usage calls are
/// also browser-reachable, and an ambient session cookie picked up from shared storage would let a
/// request succeed as the wrong account — or succeed with no bearer token at all, which would hide
/// an expired credential instead of reporting it.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: Duration = .seconds(20)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = TimeInterval(timeout.components.seconds)
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (body, response) = try await session.data(for: Self.urlRequest(from: request))
            guard let http = response as? HTTPURLResponse else {
                throw UsageError.transportFailure()
            }
            return HTTPResponse(
                status: http.statusCode,
                headers: Self.headers(of: http),
                body: body
            )
        } catch {
            throw Self.failure(from: error)
        }
    }

    static func urlRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name] = value
        }
        return headers
    }

    /// A transport-layer failure as the one error type the rest of Usage handles.
    ///
    /// A cancelled request is reported as cancelled rather than as a network failure, because the
    /// refresh policy must not count a user quitting the popover as a reason to back off.
    static func failure(from error: any Error) -> UsageError {
        if let url = error as? URLError, url.code == .cancelled { return .cancelled() }
        return UsageError.normalized(error)
    }
}
