import Flutter
import UIKit

public final class NotifieFlutterPlugin: NSObject, FlutterPlugin {

  /// Guards the state below.
  ///
  /// The channel handler runs on the platform thread, while the notification
  /// callbacks the host forwards arrive on queues the platform chooses. Nothing
  /// here may assume the two share a thread.
  private static let stateLock = NSLock()
  private static var channel: FlutterMethodChannel?
  private static var pendingOpens: [[String: Any]] = []
  private static var pendingReceipts: [[String: Any]] = []
  private static var dartHandlerReady = false

  /// Buffering only has to cover the gap before Dart attaches. If it never
  /// attaches — a host that registers the plugin but never listens — the
  /// buffer must still not grow without bound.
  private static let maxBufferedNotifications = 64

  /// A remote push carries `gk_invocation_id`. A local notification scheduled
  /// through this SDK carries `notifie_local_id` and never an invocation id, so
  /// requiring the remote key alone discarded every local tap on iOS.
  private static let invocationIdKey = "gk_invocation_id"
  private static let localIdKey = "notifie_local_id"

  private enum NotificationKind {
    case opened
    case received

    var channelMethod: String {
      switch self {
      case .opened: return "notificationOpened"
      case .received: return "notificationReceived"
      }
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "notifie_flutter/notifications",
      binaryMessenger: registrar.messenger()
    )

    stateLock.lock()
    self.channel = channel
    // A fresh registration means a fresh Dart isolate with no handler attached
    // yet. Leaving this set sent opens into the previous channel, where nothing
    // was listening and nothing buffered them either.
    dartHandlerReady = false
    stateLock.unlock()

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "markOpenHandlerReady":
        result(drainBufferedNotifications())

      case "scheduleLocalNotification":
        guard let arguments = call.arguments as? [String: Any] else {
          result(["error": "invalid_request", "message": "arguments are required"])
          return
        }
        // `@MainActor` because Flutter requires the reply on the platform
        // thread, and a bare `Task` resumes on the cooperative pool instead.
        Task { @MainActor in
          result(await LocalNotificationBridge.schedule(arguments))
        }

      case "cancelLocalNotification":
        if let arguments = call.arguments as? [String: Any] {
          LocalNotificationBridge.cancel(arguments)
        }
        result(nil)

      case "pendingLocalNotifications":
        Task { @MainActor in
          result(await LocalNotificationBridge.pending())
        }

      case "localNotificationCapabilities":
        Task { @MainActor in
          result(await LocalNotificationBridge.capabilities())
        }

      case "requestNotificationPermission":
        Task { @MainActor in
          result(await LocalNotificationBridge.requestPermission())
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Hands Dart everything buffered before it was listening, and marks it ready.
  private static func drainBufferedNotifications() -> [String: Any] {
    stateLock.lock()
    defer { stateLock.unlock() }

    let buffered: [String: Any] = [
      "opens": pendingOpens,
      "receipts": pendingReceipts,
    ]
    pendingOpens.removeAll()
    pendingReceipts.removeAll()
    dartHandlerReady = true
    return buffered
  }

  public static func recordNotificationOpened(_ userInfo: [AnyHashable: Any]) {
    record(userInfo, as: .opened)
  }

  public static func recordNotificationReceived(_ userInfo: [AnyHashable: Any]) {
    record(userInfo, as: .received)
  }

  private static func record(_ userInfo: [AnyHashable: Any], as kind: NotificationKind) {
    guard let data = notifieNotification(from: userInfo) else { return }

    stateLock.lock()
    let target = dartHandlerReady ? channel : nil
    if target == nil {
      switch kind {
      case .opened: buffer(&pendingOpens, data)
      case .received: buffer(&pendingReceipts, data)
      }
    }
    stateLock.unlock()

    guard let target else { return }
    // `invokeMethod` must be called on the platform thread, which the host's
    // notification callbacks do not promise.
    onMainThread { target.invokeMethod(kind.channelMethod, arguments: data) }
  }

  private static func buffer(_ entries: inout [[String: Any]], _ data: [String: Any]) {
    entries.append(data)
    if entries.count > maxBufferedNotifications {
      entries.removeFirst(entries.count - maxBufferedNotifications)
    }
  }

  /// Reports only Notifie's own notifications, remote or local. Anything the
  /// host application scheduled itself stays its own business.
  private static func notifieNotification(
    from userInfo: [AnyHashable: Any]
  ) -> [String: Any]? {
    let data = userInfo.reduce(into: [String: Any]()) { output, entry in
      output[String(describing: entry.key)] = entry.value
    }
    guard data[invocationIdKey] != nil || data[localIdKey] != nil else { return nil }
    return data
  }

  private static func onMainThread(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}
