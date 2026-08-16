import Foundation
import Notifie

/// Drives the real SDK against a running Notifie API.
///
/// Usage: notifie-example <apiKey> [baseURL]
///
/// This is the integration counterpart to the unit tests: it uses the live
/// URLSession transport, so it proves the wire format the SDK actually emits is
/// accepted by the server.

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: notifie-example <apiKey> [baseURL]\n".utf8)
    )
    exit(2)
}

let apiKey = arguments[1]
let baseURL = URL(string: arguments.count >= 3 ? arguments[2] : "http://127.0.0.1:3000")!

Notifie.initialize(
    apiKey: apiKey,
    baseURL: baseURL,
    batchSize: 100,
    flushInterval: 3600,
    logLevel: .debug
)

// Anonymous activity, before the user has an account.
Notifie.track("app_open")
Notifie.track("onboarding_completed", properties: ["variant": .string("b")])

Notifie.identify("swift-sdk-user", properties: [
    "plan": .string("trial"),
    "premium": .bool(false)
])

Notifie.track(
    "purchase_completed",
    properties: [
        "amount": .double(9.99),
        "plan": .string("monthly"),
        "trial": .bool(false),
        "coupon": .null
    ]
)
Notifie.identify("swift-sdk-user", properties: ["premium": .bool(true)])

await Notifie.flush()

// identify is fire-and-forget; give it a moment to land
// before the process exits.
try? await Task.sleep(nanoseconds: 2_000_000_000)

print("example: finished")
