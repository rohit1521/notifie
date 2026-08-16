import Foundation

public enum LogLevel: Int, Sendable {
    case silent = 0
    case error = 1
    case debug = 2
}

struct NotifieLogger: Sendable {
    let level: LogLevel

    func debug(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.debug.rawValue else { return }
        print("[Notifie DEBUG] \(message())")
    }

    func error(_ message: @autoclosure () -> String) {
        guard level.rawValue >= LogLevel.error.rawValue else { return }
        print("[Notifie ERROR] \(message())")
    }
}
