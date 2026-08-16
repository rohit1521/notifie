import Foundation

/// Configures the Notifie SDK.
public struct NotifieConfiguration: Sendable {
    public let apiKey: String
    public let baseURL: URL
    /// Events per batch before an automatic flush.
    public let batchSize: Int
    /// Seconds between timer-driven flushes.
    public let flushInterval: TimeInterval
    /// Maximum events kept in queue; oldest dropped when exceeded.
    public let maxQueueSize: Int
    public let logLevel: LogLevel

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "http://127.0.0.1:3000")!,
        batchSize: Int = 20,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        logLevel: LogLevel = .silent
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.batchSize = min(max(batchSize, 1), 100)
        self.flushInterval = flushInterval
        self.maxQueueSize = max(maxQueueSize, 1)
        self.logLevel = logLevel
    }
}
