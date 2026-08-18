import Foundation

/// Buffers events and delivers them in batches.
///
/// A single actor owns the pending list, the in-flight guard and the retry
/// schedule, so a timer tick, a batch-size trigger and a retry wake-up cannot
/// send the same events concurrently.
actor EventQueue {
    private var pending: [NotifieEvent] = []
    private let config: NotifieConfiguration
    private let transport: Transport
    private let storage: Storage
    private let logger: NotifieLogger

    private var flushTimer: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// The delivery currently in progress, if any. Concurrent callers await it
    /// rather than starting a second one.
    private var flushTask: Task<Void, Never>?
    private var pushOperationTask: Task<Bool, Never>?
    private var pushOperationSequence = 0

    private var retryCount = 0
    private var retryAt: Date?

    /// The server caps a batch at 100 regardless of the configured batch size.
    private let maxBatchSize = 100
    private let maxBackoffSeconds = 300.0

    init(
        config: NotifieConfiguration,
        transport: Transport,
        storage: Storage,
        logger: NotifieLogger
    ) {
        self.config = config
        self.transport = transport
        self.storage = storage
        self.logger = logger
        self.pending = storage.loadQueue()
    }

    func startTimer() {
        flushTimer?.cancel()
        let interval = config.flushInterval
        flushTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                _ = await self?.flushPushTokenLifecycle()
                // Events first: the server merges an anonymous history into the
                // external user on identify, so a backlog must land before it.
                await self?.flush()
                await self?.flushPendingIdentify()
            }
        }
    }

    func stopTimer() {
        flushTimer?.cancel()
        flushTimer = nil
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Enqueue

    func enqueue(_ event: NotifieEvent) {
        pending.append(event)

        if pending.count > config.maxQueueSize {
            let overflow = pending.count - config.maxQueueSize
            pending.removeFirst(overflow)
            logger.debug("Queue cap exceeded; dropped \(overflow) oldest event(s)")
        }

        persist()

        if pending.count >= config.batchSize {
            Task { await self.flush() }
        }
    }

    // MARK: - Flush

    /// Delivers everything currently queued.
    ///
    /// Overlapping callers (timer tick, batch-size trigger, an explicit
    /// `Notifie.flush()`) coalesce onto a single delivery: they neither send the
    /// same batch twice nor return before the queue has actually been drained.
    func flush() async {
        if let existing = flushTask {
            await existing.value
            return
        }

        guard !pending.isEmpty else { return }
        // Honour backoff; the retry task calls back when the delay elapses.
        if let retryAt, retryAt > Date() { return }

        let task = Task { await self.drain() }
        flushTask = task
        await task.value

        // Only clear our own registration; a later caller may have replaced it.
        if flushTask == task { flushTask = nil }
    }

    /// Drains in a loop so a backlog from an offline period clears in one pass
    /// rather than one batch per flush interval.
    private func drain() async {
        while !pending.isEmpty {
            let batch = Array(pending.prefix(maxBatchSize))

            switch await send(batch) {
            case .delivered, .permanentlyRejected:
                remove(batch)
                persist()
                retryCount = 0
                retryAt = nil
            case .retryable:
                scheduleRetry()
                return
            }
        }
    }

    private enum SendOutcome {
        case delivered
        case permanentlyRejected
        case retryable
    }

    /// How the SDK reacts to a response status.
    ///
    /// Shared by events, identify and revocations deliberately. When each
    /// endpoint classified statuses for itself they disagreed: a 404 was fatal
    /// for a batch of events but retried forever for a revocation, which is
    /// what let one dead token block every later push registration.
    private enum ResponseClass {
        case success
        /// The server will never accept this payload. Retrying cannot help, and
        /// keeping it queued blocks everything behind it.
        case permanent
        /// Transient. The identical request may succeed later.
        case retryable
    }

    private func classify(_ statusCode: Int) -> ResponseClass {
        switch statusCode {
        case 200...299:
            return .success
        // 408 and 425 mean "ask again", not "never". They previously fell into
        // the default branch and were dropped as permanent, losing events the
        // server SDK would have retried.
        case 408, 425, 429:
            return .retryable
        case 500...599:
            return .retryable
        default:
            return .permanent
        }
    }

    private func send(_ events: [NotifieEvent]) async -> SendOutcome {
        do {
            let request = try buildEventsRequest(events)
            let (_, response) = try await transport.send(request: request)

            switch classify(response.statusCode) {
            case .success:
                logger.debug("Flushed \(events.count) event(s)")
                return .delivered
            case .permanent:
                // Retrying cannot help, and leaving the batch queued would block
                // every later event behind it forever.
                logger.error("Dropping \(events.count) event(s): HTTP \(response.statusCode)")
                return .permanentlyRejected
            case .retryable:
                logger.error("HTTP \(response.statusCode); will retry with backoff")
                return .retryable
            }
        } catch {
            logger.error("Network error: \(error)")
            return .retryable
        }
    }

    private func scheduleRetry() {
        retryCount += 1

        let base = min(pow(2.0, Double(retryCount)), maxBackoffSeconds)
        // Jitter spreads retries so a recovering server is not thundered.
        let jitter = Double.random(in: -0.3...0.3) * base
        let delay = max(1.0, base + jitter)

        retryAt = Date().addingTimeInterval(delay)
        logger.debug("Retry #\(retryCount) in \(String(format: "%.1f", delay))s")

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.clearRetryGate()
            await self?.flush()
        }
    }

    private func clearRetryGate() {
        retryAt = nil
    }

    private func remove(_ events: [NotifieEvent]) {
        let ids = Set(events.map(\.messageId))
        pending.removeAll { ids.contains($0.messageId) }
    }

    private func persist() {
        storage.saveQueue(pending)
    }

    // MARK: - Requests

    private func authorizedRequest(_ path: String) -> URLRequest {
        let url = config.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func buildEventsRequest(_ events: [NotifieEvent]) throws -> URLRequest {
        var request = authorizedRequest("events")
        request.httpBody = try Storage.encoder.encode(TrackBatchBody(events: events, sentAt: Date()))
        return request
    }

    /// Routed through the queue's transport so a custom or mock transport
    /// applies to identify calls too, not just events.
    ///
    /// Persists before attempting delivery: a one-shot attempt lost the
    /// identity permanently whenever the device happened to be offline.
    func sendIdentify(_ body: IdentifyBody) async {
        storage.savePendingIdentify(body)
        await deliverPendingIdentify()
    }

    /// Replays an identify an earlier attempt could not deliver. Driven by the
    /// same timer as the event flush, so recovery needs no extra caller.
    func flushPendingIdentify() async {
        guard storage.pendingIdentify() != nil else { return }
        await deliverPendingIdentify()
    }

    private func deliverPendingIdentify() async {
        guard let body = storage.pendingIdentify() else { return }

        do {
            var request = authorizedRequest("identify")
            request.httpBody = try Storage.encoder.encode(body)
            let (_, response) = try await transport.send(request: request)

            switch classify(response.statusCode) {
            case .success:
                storage.completePendingIdentify(body)
            case .permanent:
                // Replaying cannot make the server accept it; keeping it would
                // retry the same rejection on every flush forever.
                logger.error("Identify rejected: HTTP \(response.statusCode)")
                storage.completePendingIdentify(body)
            case .retryable:
                logger.error("Identify failed: HTTP \(response.statusCode); will retry")
            }
        } catch {
            logger.error("Identify failed: \(error)")
        }
    }

    /// Fire-and-forget push token registration.  Mirrors sendIdentify: one
    /// attempt per call, logged on failure, no queuing — token re-registration
    /// on the next identify or the next explicit registerPushToken call acts as
    /// a natural retry without needing the event backoff machinery.
    private func sendPushToken(_ body: PushTokenBody) async -> Bool {
        do {
            var request = authorizedRequest("push-tokens")
            request.httpBody = try Storage.encoder.encode(body)
            let (_, response) = try await transport.send(request: request)

            if !(200...299).contains(response.statusCode) {
                logger.error("Push token registration failed: HTTP \(response.statusCode)")
                return false
            }
            return true
        } catch {
            logger.error("Push token registration failed: \(error)")
            return false
        }
    }

    /**
     Replays explicit token revocations until the server confirms them.

     The pending list lives in UserDefaults, so an offline logout followed by
     a cold kill cannot leave the previous user subscribed indefinitely.
     */
    func flushPushTokenLifecycle() async -> Bool {
        let previous = pushOperationTask
        pushOperationSequence += 1
        let sequence = pushOperationSequence
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performPushTokenLifecycle()
        }
        pushOperationTask = task
        let result = await task.value
        if pushOperationSequence == sequence {
            pushOperationTask = nil
        }
        return result
    }

    private func performPushTokenLifecycle() async -> Bool {
        guard await flushPushTokenRevocations() else { return false }
        let state = storage.pendingPushLifecycleState()
        // A revocation queued while an earlier DELETE was suspended must run
        // before any registration can be claimed.
        guard !state.hasRevocations else { return false }
        guard let registration = state.registration else {
            return true
        }
        guard await sendPushToken(registration) else { return false }
        storage.completePendingPushTokenRegistration(registration)
        return true
    }

    private func flushPushTokenRevocations() async -> Bool {
        for token in storage.pendingPushTokenRevocations() {
            do {
                var request = authorizedRequest("push-tokens")
                request.httpMethod = "DELETE"
                request.httpBody = try Storage.encoder.encode(PushTokenRevocationBody(token: token))
                let (_, response) = try await transport.send(request: request)

                switch classify(response.statusCode) {
                case .success:
                    storage.completePushTokenRevocation(token)
                case .permanent:
                    // The server will never accept this token — most often a 404
                    // because it is already gone. Discarding it is what stops one
                    // dead token from blocking every future registration.
                    logger.debug(
                        "Discarding unacceptable revocation: HTTP \(response.statusCode)"
                    )
                    storage.completePushTokenRevocation(token)
                case .retryable:
                    logger.error("Push token revocation failed: HTTP \(response.statusCode)")
                    return false
                }
            } catch {
                logger.error("Push token revocation failed: \(error)")
                return false
            }
        }
        return true
    }

    // MARK: - Reset

    func reset() {
        pending.removeAll()
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        retryAt = nil
        storage.clearQueue()
    }

    // MARK: - Introspection (tests)

    var count: Int { pending.count }

    func peekAll() -> [NotifieEvent] { pending }

    var currentRetryCount: Int { retryCount }
}
