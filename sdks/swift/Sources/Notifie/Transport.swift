import Foundation

/// Abstraction over URLSession so tests never touch the network.
public protocol Transport: Sendable {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live transport backed by URLSession.
public final class URLSessionTransport: Transport, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        return (data, http)
    }
}

public enum TransportError: Error {
    case invalidResponse
}
