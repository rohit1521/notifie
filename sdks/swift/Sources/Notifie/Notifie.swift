import Foundation
#if canImport(UIKit)
import UIKit
#endif

private let eventNameRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"^[A-Za-z0-9][A-Za-z0-9 _.:-]*$"#
)

/// The public surface of Notifie.
///
/// Deliberately three methods: initialize, identify and track.
/// Everything else — batching, retries, identity, persistence — is internal.
public final class Notifie: @unchecked Sendable {

    public static let shared = Notifie()
    internal init() {}

    // Lock rather than actor isolation so callers never have to `await` a
    // fire-and-forget call like `track()`.
    private let lock = NSLock()
    private var _queue: EventQueue?
    private var _config: NotifieConfiguration?
    private var _storage: Storage?
    private var _userId: String?
    private var _logger = NotifieLogger(level: .silent)
    /// Properties set before any user was identified. Held until an identity
    /// exists, since the server keys user properties by external id.
    private var _bufferedProperties: Properties = [:]
    private var _backgroundObserverRegistered = false
    /// Serialises identify deliveries. Without it two rapid calls race and the
    /// server can apply the older property value last.
    private var _identifyChain: Task<Void, Never>?
    private var _resetChain: Task<Void, Never>?
    private var _generation: UInt64 = 0

    // MARK: - Initialize

    public static func initialize(
        apiKey: String,
        baseURL: URL = URL(string: "https://notifie.dev")!,
        batchSize: Int = 20,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        logLevel: LogLevel = .silent,
        transport: Transport = URLSessionTransport()
    ) {
        shared.setup(
            config: NotifieConfiguration(
                apiKey: apiKey,
                baseURL: baseURL,
                batchSize: batchSize,
                flushInterval: flushInterval,
                maxQueueSize: maxQueueSize,
                logLevel: logLevel
            ),
            transport: transport,
            storage: .production()
        )
    }

    /// Injectable seam for tests.
    func setup(config: NotifieConfiguration, transport: Transport, storage: Storage) {
        let logger = NotifieLogger(level: config.logLevel)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: logger)

        lock.withLock {
            _generation &+= 1
            _queue = queue
            _config = config
            _storage = storage
            _logger = logger
            _userId = nil
            _bufferedProperties = [:]
            _identifyChain = nil
            _resetChain = nil
        }

        Task {
            await queue.startTimer()
            _ = await queue.flushPushTokenLifecycle()
        }
        registerBackgroundObserver()
        trackLifecycle()
    }

    /**
     Emits the events Notifie can detect without knowing anything about the app.

     This is what makes the SDK useful the moment it is installed. `first_open`
     and `app_open` require no domain knowledge, and on their own they unlock the
     retention templates — so a developer who has written nothing but
     `Notifie.initialize` still gets recommendations.

     Anything beyond lifecycle is deliberately not guessed at. No SDK can know
     what a "purchase" means in an arbitrary app, and inventing one from
     swizzled StoreKit or screen names produces events the developer did not
     write and cannot trust.
     */
    private func trackLifecycle() {
        let storage = lock.withLock { _storage }
        guard let storage else { return }

        let context = DeviceContext.current()

        if storage.markInstalledIfNeeded() {
            // `install` is the canonical name; `first_open` is kept because
            // existing templates and docs already reference it.
            performTrack(eventName: "install", properties: context.asProperties())
            performTrack(eventName: "first_open", properties: [:])
        }

        performTrack(eventName: "app_open", properties: context.asProperties())
        // A session is a launch or a return from background. Emitted alongside
        // app_open so either name works as a trigger.
        performTrack(eventName: "session_start", properties: [:])
        registerForegroundObserver()
    }

    private var _foregroundObserverRegistered = false

    /// A launch is not the only session: returning from background is one too,
    /// and it is the signal every retention template actually depends on.
    private func registerForegroundObserver() {
        let already = lock.withLock {
            let was = _foregroundObserverRegistered
            _foregroundObserverRegistered = true
            return was
        }
        guard !already else { return }

#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.performTrack(eventName: "app_open", properties: [:])
            self?.performTrack(eventName: "session_start", properties: [:])
        }
#endif
    }

    // MARK: - Public API
    //
    // Three methods, deliberately. Anything a developer has to learn is a cost
    // paid before they get any value, so the surface stays at the minimum that
    // still expresses "who is this" and "what happened".

    /// Associates all future events with a user identity, optionally setting
    /// profile properties at the same time.
    public static func identify(_ userId: String, properties: Properties = [:]) {
        shared.performIdentify(userId: userId, properties: properties)
    }

    /// Records a named event with optional flat-scalar properties.
    public static func track(_ eventName: String, properties: Properties = [:]) {
        shared.performTrack(eventName: eventName, properties: properties)
    }

    // MARK: - Push token registration
    //
    // The SDK never requests notification permission on its own — that decision
    // belongs to the host app (UNUserNotificationCenter.requestAuthorization).
    // Call registerPushToken from didRegisterForRemoteNotificationsWithDeviceToken.

    /// Registers a raw APNs device token with Notifie.
    ///
    /// Converts the binary token to lowercase hex, persists it locally, and
    /// sends it to the server.  If called before `initialize()`, the call is
    /// silently ignored — no crash.
    public static func registerPushToken(_ deviceToken: Data) {
        // %02x pads single-digit bytes (e.g. 0x0f → "0f") so the hex string
        // is always 64 characters for a 32-byte APNs token.
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        shared.performRegisterPushToken(hex, platform: "ios", provider: "apns")
    }

    /// String overload for cross-platform bridges (Flutter / React Native).
    ///
    /// Provide the hex-encoded token string plus the target platform and
    /// provider.  Defaults match the iOS/APNs case.
    public static func registerPushToken(
        _ token: String,
        platform: String = "ios",
        provider: String = "apns"
    ) {
        shared.performRegisterPushToken(token, platform: platform, provider: provider)
    }

    // MARK: - Operational conveniences

    public static func flush() async {
        await shared.pendingReset?.value
        // Awaits in-flight identify calls too, so a caller that flushes after
        // setting properties sees them delivered.
        await shared.pendingIdentify?.value
        await shared.currentQueue?.flush()
        // Retries an identify an earlier attempt could not deliver, so an
        // explicit flush recovers it rather than waiting for the timer.
        await shared.currentQueue?.flushPendingIdentify()
    }

    /// Clears the identity and any queued events. Call on logout so the next
    /// user does not inherit the previous one's anonymous id.
    public static func reset() {
        shared.performReset()
    }

    // MARK: - Implementation

    /// Flushes this instance rather than the shared singleton, so tests can
    /// drive an isolated Notifie without touching global state.
    func flushForTesting() async {
        await pendingReset?.value
        await pendingIdentify?.value
        await currentQueue?.flush()
        await currentQueue?.flushPendingIdentify()
    }

    func resetForTesting() {
        performReset()
    }

    func flushPushLifecycleForTesting() async {
        _ = await currentQueue?.flushPushTokenLifecycle()
    }

    /// True once `initialize()` has run. Used by extensions in other files.
    var isInitialised: Bool { lock.withLock { _queue != nil } }

    func logWarning(_ message: String) {
        lock.withLock { _logger }.error(message)
    }

    private var currentQueue: EventQueue? { lock.withLock { _queue } }

    private var pendingIdentify: Task<Void, Never>? { lock.withLock { _identifyChain } }
    private var pendingReset: Task<Void, Never>? { lock.withLock { _resetChain } }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { _generation == generation }
    }

    private func savePendingPushTokenRegistration(
        _ body: PushTokenBody,
        storage: Storage,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard _generation == generation else { return false }
            storage.savePendingPushTokenRegistration(body)
            return true
        }
    }

    func performIdentify(userId: String, properties: Properties) {
        guard !userId.isEmpty else {
            lock.withLock { _logger }.error("identify() requires a non-empty userId — ignoring")
            return
        }

        let started = lock.withLock { () -> Bool in
            guard let queue = _queue, let storage = _storage else { return false }

            let generation = _generation
            let reset = _resetChain
            let previous = _identifyChain
            _userId = userId
            var merged = _bufferedProperties
            for (key, value) in properties { merged[key] = value }
            _bufferedProperties = [:]
            let anonymousId = storage.anonymousId()
            let body = IdentifyBody(
                userId: userId,
                anonymousId: anonymousId,
                properties: merged,
                timestamp: Date()
            )

            let task = Task { [weak self] in
                await reset?.value
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentGeneration(generation) else { return }

                await previous?.value
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }

                // Anonymous events queued before identify must arrive before the
                // server merges that identity into the external user.
                await queue.flush()
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }

                await queue.sendIdentify(body)
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }

                if let storedToken = storage.pushToken(),
                   let platform = storage.pushPlatform(),
                   let provider = storage.pushProvider() {
                    let pushBody = PushTokenBody(
                        userId: userId,
                        anonymousId: anonymousId,
                        token: storedToken,
                        platform: platform,
                        provider: provider
                    )
                    guard self.savePendingPushTokenRegistration(
                        pushBody,
                        storage: storage,
                        generation: generation
                    ) else { return }
                    _ = await queue.flushPushTokenLifecycle()
                }
            }
            _identifyChain = task
            return true
        }

        guard started else {
            lock.withLock { _logger }.error("identify() called before initialize() — ignoring")
            return
        }
    }

    func performRegisterPushToken(_ token: String, platform: String, provider: String) {
        guard !token.isEmpty,
              token.count <= 512,
              ["ios", "android"].contains(platform),
              ["apns", "fcm"].contains(provider) else {
            lock.withLock { _logger }.error("Invalid push token registration — ignoring")
            return
        }

        let state: (
            queue: EventQueue,
            generation: UInt64,
            reset: Task<Void, Never>?
        )? = lock.withLock {
            guard let queue = _queue, let storage = _storage else { return nil }
            storage.savePushToken(token, platform: platform, provider: provider)
            let body = PushTokenBody(
                userId: _userId,
                anonymousId: storage.anonymousId(),
                token: token,
                platform: platform,
                provider: provider
            )
            storage.savePendingPushTokenRegistration(body)
            return (queue, _generation, _resetChain)
        }

        guard let state else {
            // Called before initialize() — silently ignore so the host app
            // never crashes if registration fires during an early launch race.
            lock.withLock { _logger }.debug("registerPushToken() called before initialize() — ignoring")
            return
        }

        Task { [weak self] in
            await state.reset?.value
            guard let self,
                  self.isCurrentGeneration(state.generation) else { return }
            _ = await state.queue.flushPushTokenLifecycle()
        }
    }

    func performTrack(
        eventName: String,
        properties: Properties,
        messageId: String? = nil
    ) {
        let state: (
            queue: EventQueue,
            userId: String?,
            anonymousId: String,
            generation: UInt64,
            reset: Task<Void, Never>?
        )? = lock.withLock {
            guard let queue = _queue, let storage = _storage else { return nil }
            return (queue, _userId, storage.anonymousId(), _generation, _resetChain)
        }

        guard let state else {
            lock.withLock { _logger }.error("track() called before initialize() — ignoring")
            return
        }

        guard isValidEventName(eventName) else {
            lock.withLock { _logger }.error("Invalid event name '\(eventName)' — ignoring")
            return
        }

        let event = NotifieEvent(
            // Generated once here and reused across retries; this is what makes
            // server-side idempotency work.
            messageId: messageId ?? UUID().uuidString.lowercased(),
            event: eventName,
            timestamp: Date(),
            userId: state.userId,
            anonymousId: state.anonymousId,
            properties: properties
        )

        Task { [weak self] in
            await state.reset?.value
            guard let self, self.isCurrentGeneration(state.generation) else { return }
            await state.queue.enqueue(event)
        }
    }

    func performSetUserProperty(_ key: String, value: NotifieProperty) {
        let userId: String? = lock.withLock {
            guard _queue != nil else { return nil }
            if let existing = _userId { return existing }
            // No identity yet: hold the property rather than sending an empty
            // userId the server would reject.
            _bufferedProperties[key] = value
            return nil
        }

        guard let userId else { return }
        performIdentify(userId: userId, properties: [key: value])
    }

    private func performReset() {
        lock.withLock {
            guard let queue = _queue, let storage = _storage else { return }
            _generation &+= 1
            let token = storage.pushToken()
            if let token {
                storage.enqueuePushTokenRevocation(token)
            }
            _userId = nil
            _bufferedProperties = [:]
            _identifyChain?.cancel()
            _identifyChain = nil
            storage.clearPendingPushTokenRegistration()
            // The previous user's identify must not be replayed after logout.
            storage.clearPendingIdentify()
            storage.clearAnonymousId()
            storage.clearPushToken()

            let previous = _resetChain
            let task = Task {
                await previous?.value
                // Clear the old identity queue before any event for the next
                // generation is allowed to enqueue.
                await queue.reset()
                if token != nil {
                    _ = await queue.flushPushTokenLifecycle()
                }
            }
            _resetChain = task
        }
    }

    // MARK: - Lifecycle

    private func registerBackgroundObserver() {
        let alreadyRegistered = lock.withLock {
            let was = _backgroundObserverRegistered
            _backgroundObserverRegistered = true
            return was
        }
        guard !alreadyRegistered else { return }

#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.currentQueue?.flush() }
        }
#endif
    }

    private func isValidEventName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard let regex = eventNameRegex else { return true }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }
}
