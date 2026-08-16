import Foundation
#if canImport(UIKit)
import UIKit
#endif

/**
 Device and app context, collected automatically.

 Every one of these is derivable without knowing anything about the app, and
 all of them are things audiences want to target: "iOS 17 users in India",
 "everyone still on 2.1.0", "send at 9am in their timezone". Asking a developer
 to pass them by hand would be asking them to write code the SDK can write
 correctly every time.
 */
struct DeviceContext: Sendable {
    let platform: String
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let locale: String
    let timezone: String
    let deviceModel: String

    static func current() -> DeviceContext {
        let bundle = Bundle.main

        return DeviceContext(
            platform: currentPlatform(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            // Identifier rather than display name, so it does not change with
            // the reader's own locale.
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            deviceModel: currentModel()
        )
    }

    /// Flat scalars only: nested objects are rejected at ingest, and these need
    /// to stay comparable for audience filters.
    func asProperties() -> Properties {
        [
            "platform": .string(platform),
            "os_version": .string(osVersion),
            "app_version": .string(appVersion),
            "app_build": .string(appBuild),
            "locale": .string(locale),
            "timezone": .string(timezone),
            "device_model": .string(deviceModel),
        ]
    }

    private static func currentPlatform() -> String {
#if os(iOS)
        return "ios"
#elseif os(macOS)
        return "macos"
#elseif os(tvOS)
        return "tvos"
#elseif os(watchOS)
        return "watchos"
#else
        return "unknown"
#endif
    }

    private static func currentModel() -> String {
#if canImport(UIKit) && os(iOS)
        // The machine identifier ("iPhone15,2") rather than the marketing name,
        // because it is stable and does not need a lookup table that goes stale
        // with every new device.
        var systemInfo = utsname()
        uname(&systemInfo)

        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }

        return identifier ?? "unknown"
#else
        return "unknown"
#endif
    }
}
