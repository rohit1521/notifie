import Foundation

/// Persists the anonymous device ID and the pending event queue to disk.
/// @unchecked because UserDefaults is not Sendable in the SDK headers, but our access
/// is confined to one-at-a-time calls through the actor/lock boundaries above.
final class Storage: @unchecked Sendable {
    private let defaults: UserDefaults
    private let queueFileURL: URL
    private let revocationLock = NSLock()
    private let identityLock = NSLock()
    private let anonymousIdKey = "gk_anonymous_id"

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Storage.isoFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = Storage.isoFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO-8601 date: \(s)"
                )
            }
            return date
        }
        return d
    }()

    init(defaults: UserDefaults, queueFileURL: URL) {
        self.defaults = defaults
        self.queueFileURL = queueFileURL
    }

    // MARK: - Anonymous ID

    func anonymousId() -> String {
        if let existing = defaults.string(forKey: anonymousIdKey) {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: anonymousIdKey)
        return id
    }

    func clearAnonymousId() {
        defaults.removeObject(forKey: anonymousIdKey)
    }

    // MARK: - First launch

    private let installedKey = "gk_installed"

    /// True exactly once per install, so `first_open` is not re-sent on every
    /// launch. Deliberately keyed separately from the anonymous id: `reset()`
    /// clears identity on logout, but the app is still installed.
    func markInstalledIfNeeded() -> Bool {
        if defaults.bool(forKey: installedKey) { return false }
        defaults.set(true, forKey: installedKey)
        return true
    }

    // MARK: - Queue persistence

    func saveQueue(_ events: [NotifieEvent]) {
        do {
            let data = try Storage.encoder.encode(events)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            // Non-fatal: next launch may lose unsent events but app won't crash.
        }
    }

    func loadQueue() -> [NotifieEvent] {
        guard let data = try? Data(contentsOf: queueFileURL) else { return [] }
        return (try? Storage.decoder.decode([NotifieEvent].self, from: data)) ?? []
    }

    func clearQueue() {
        try? FileManager.default.removeItem(at: queueFileURL)
    }

    // MARK: - Pending identify

    private let pendingIdentifyKey = "gk_pending_identify"

    /**
     Holds an identify that has not been accepted yet.

     Identify is not requeued through the event queue because it is not an
     event: the server keys user properties by external id and applies them
     last-write-wins, so replaying the newest call is correct where replaying a
     backlog would not be. Persisting it means an identify made on a plane is
     still delivered on landing rather than lost with the process.
     */
    func pendingIdentify() -> IdentifyBody? {
        identityLock.withLock {
            guard let data = defaults.data(forKey: pendingIdentifyKey) else { return nil }
            return try? Storage.decoder.decode(IdentifyBody.self, from: data)
        }
    }

    func savePendingIdentify(_ body: IdentifyBody) {
        identityLock.withLock {
            guard let data = try? Storage.encoder.encode(body) else { return }
            defaults.set(data, forKey: pendingIdentifyKey)
        }
    }

    /// Clears only when the stored value is still the one just delivered, so a
    /// newer identify queued mid-flight is not discarded by an older success.
    func completePendingIdentify(_ body: IdentifyBody) {
        identityLock.withLock {
            guard let data = defaults.data(forKey: pendingIdentifyKey),
                  let current = try? Storage.decoder.decode(IdentifyBody.self, from: data),
                  current == body else { return }
            defaults.removeObject(forKey: pendingIdentifyKey)
        }
    }

    func clearPendingIdentify() {
        identityLock.withLock {
            defaults.removeObject(forKey: pendingIdentifyKey)
        }
    }

    // MARK: - Push token

    private let pushTokenKey    = "gk_push_token"
    private let pushPlatformKey = "gk_push_platform"
    private let pushProviderKey = "gk_push_provider"
    private let pendingPushTokenRevocationsKey = "gk_pending_push_token_revocations"
    private let pendingPushTokenRegistrationKey = "gk_pending_push_token_registration"

    func pushToken() -> String? { defaults.string(forKey: pushTokenKey) }
    func pushPlatform() -> String? { defaults.string(forKey: pushPlatformKey) }
    func pushProvider() -> String? { defaults.string(forKey: pushProviderKey) }

    func savePushToken(_ token: String, platform: String, provider: String) {
        defaults.set(token, forKey: pushTokenKey)
        defaults.set(platform, forKey: pushPlatformKey)
        defaults.set(provider, forKey: pushProviderKey)
    }

    func clearPushToken() {
        defaults.removeObject(forKey: pushTokenKey)
        defaults.removeObject(forKey: pushPlatformKey)
        defaults.removeObject(forKey: pushProviderKey)
    }

    func pendingPushTokenRegistration() -> PushTokenBody? {
        revocationLock.withLock {
            guard let data = defaults.data(forKey: pendingPushTokenRegistrationKey) else {
                return nil
            }

            return try? Storage.decoder.decode(PushTokenBody.self, from: data)
        }
    }

    func pendingPushLifecycleState() -> (
        hasRevocations: Bool,
        registration: PushTokenBody?
    ) {
        revocationLock.withLock {
            let revocations = defaults.stringArray(
                forKey: pendingPushTokenRevocationsKey
            ) ?? []
            guard revocations.isEmpty else {
                return (true, nil)
            }
            guard let data = defaults.data(forKey: pendingPushTokenRegistrationKey)
            else { return (false, nil) }
            return (
                false,
                try? Storage.decoder.decode(PushTokenBody.self, from: data)
            )
        }
    }

    func savePendingPushTokenRegistration(_ body: PushTokenBody) {
        revocationLock.withLock {
            guard let data = try? Storage.encoder.encode(body) else { return }
            defaults.set(data, forKey: pendingPushTokenRegistrationKey)
        }
    }

    func completePendingPushTokenRegistration(_ body: PushTokenBody) {
        revocationLock.withLock {
            guard let data = defaults.data(forKey: pendingPushTokenRegistrationKey),
                  let current = try? Storage.decoder.decode(PushTokenBody.self, from: data),
                  current == body else { return }
            defaults.removeObject(forKey: pendingPushTokenRegistrationKey)
        }
    }

    func clearPendingPushTokenRegistration() {
        revocationLock.withLock {
            defaults.removeObject(forKey: pendingPushTokenRegistrationKey)
        }
    }

    func pendingPushTokenRevocations() -> [String] {
        revocationLock.withLock {
            defaults.stringArray(forKey: pendingPushTokenRevocationsKey) ?? []
        }
    }

    func enqueuePushTokenRevocation(_ token: String) {
        revocationLock.withLock {
            var pending = defaults.stringArray(forKey: pendingPushTokenRevocationsKey) ?? []
            guard !pending.contains(token) else { return }
            pending.append(token)
            defaults.set(pending, forKey: pendingPushTokenRevocationsKey)
        }
    }

    func completePushTokenRevocation(_ token: String) {
        revocationLock.withLock {
            let pending = defaults.stringArray(forKey: pendingPushTokenRevocationsKey) ?? []
            let remaining = pending.filter { $0 != token }
            if remaining.isEmpty {
                defaults.removeObject(forKey: pendingPushTokenRevocationsKey)
            } else {
                defaults.set(remaining, forKey: pendingPushTokenRevocationsKey)
            }
        }
    }
}

extension Storage {
    /// Convenience: production storage in Application Support.
    static func production() -> Storage {
        let dir: URL
        if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let gkDir = appSupport.appendingPathComponent("Notifie", isDirectory: true)
            try? FileManager.default.createDirectory(at: gkDir, withIntermediateDirectories: true)
            dir = gkDir
        } else {
            dir = FileManager.default.temporaryDirectory
        }
        return Storage(
            defaults: .standard,
            queueFileURL: dir.appendingPathComponent("gk_queue.json")
        )
    }
}
