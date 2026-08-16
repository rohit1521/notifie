import Flutter
import UIKit

public final class NotifieFlutterPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?
  private static var pendingOpens: [[String: Any]] = []
  private static var pendingReceipts: [[String: Any]] = []
  private static var dartHandlerReady = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "notifie_flutter/notifications",
      binaryMessenger: registrar.messenger()
    )
    self.channel = channel
    channel.setMethodCallHandler { call, result in
    switch call.method {
    case "markOpenHandlerReady":
      dartHandlerReady = true
      let pending: [String: Any] = [
        "opens": pendingOpens,
        "receipts": pendingReceipts,
      ]
      pendingOpens.removeAll()
      pendingReceipts.removeAll()
      result(pending)

    case "scheduleLocalNotification":
      guard let arguments = call.arguments as? [String: Any] else {
        result(["error": "invalid_request", "message": "arguments are required"])
        return
      }
      Task { result(await LocalNotificationBridge.schedule(arguments)) }

    case "cancelLocalNotification":
      if let arguments = call.arguments as? [String: Any] {
        LocalNotificationBridge.cancel(arguments)
      }
      result(nil)

    case "pendingLocalNotifications":
      Task { result(await LocalNotificationBridge.pending()) }

    case "localNotificationCapabilities":
      Task { result(await LocalNotificationBridge.capabilities()) }

    case "requestNotificationPermission":
      Task { result(await LocalNotificationBridge.requestPermission()) }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
  }


  public static func recordNotificationOpened(_ userInfo: [AnyHashable: Any]) {
    let data = userInfo.reduce(into: [String: Any]()) { output, entry in
      output[String(describing: entry.key)] = entry.value
    }
    guard data["gk_invocation_id"] != nil else { return }
    if dartHandlerReady, let channel {
      channel.invokeMethod("notificationOpened", arguments: data)
    } else {
      pendingOpens.append(data)
    }
  }

  public static func recordNotificationReceived(_ userInfo: [AnyHashable: Any]) {
    let data = userInfo.reduce(into: [String: Any]()) { output, entry in
      output[String(describing: entry.key)] = entry.value
    }
    guard data["gk_invocation_id"] != nil else { return }
    if dartHandlerReady, let channel {
      channel.invokeMethod("notificationReceived", arguments: data)
    } else {
      pendingReceipts.append(data)
    }
  }
}
