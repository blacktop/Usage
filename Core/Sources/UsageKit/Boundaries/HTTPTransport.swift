import Foundation

public struct HTTPRequest: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable, CaseIterable {
        case get = "GET"
        case post = "POST"
    }

    public let method: Method
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil)
    {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public func headerValue(_ name: String) -> String? {
        HeaderLookup.value(named: name, in: headers)
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200...299).contains(status) }

    public func headerValue(_ name: String) -> String? {
        HeaderLookup.value(named: name, in: headers)
    }
}

/// The single network boundary. Everything above it is pure enough to test with fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

enum HeaderLookup {
    static func value(named name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}
