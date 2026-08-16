export type NotifieProperty = string | number | boolean | null;
export type NotifieProperties = Record<string, NotifieProperty>;

export interface PushRegistration {
  token: string;
  platform: 'ios' | 'android';
  provider: 'fcm';
}

export interface NotifieNotification {
  title?: string;
  body?: string;
  data: Record<string, string>;
  invocationId?: string;
  deepLink?: string;
  imageUrl?: string;
}

export interface PushTokenProvider {
  enableNotifications(): Promise<PushRegistration | null>;
  subscribeToTokenRefresh?(listener: (registration: PushRegistration) => void): () => void;
  subscribeToForegroundNotifications?(
    listener: (notification: NotifieNotification) => void,
  ): () => void;
  subscribeToOpenedNotifications?(
    listener: (notification: NotifieNotification) => void,
  ): () => void;
  getInitialNotification?(): Promise<NotifieNotification | null>;
}

export interface NotifieStorage {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

export type NotifieFetch = (
  input: string | Request,
  init?: RequestInit,
) => Promise<Response>;

export interface NotifieClientOptions {
  storage?: NotifieStorage;
  batchSize?: number;
  maxQueueSize?: number;
  flushIntervalMs?: number;
  retryBaseMs?: number;
  requestTimeoutMs?: number;
  autoFlushOnStart?: boolean;
  now?: () => Date;
  messageIdFactory?: () => string;
  onNotificationReceived?: (notification: NotifieNotification) => void;
  onNotificationOpened?: (notification: NotifieNotification) => void;
  onError?: (error: unknown) => void;
}

type QueuedEvent = {
  messageId: string;
  anonymousId: string;
  userId?: string;
  event: string;
  timestamp: string;
  properties: NotifieProperties;
};

type HttpResult = {
  status: number;
  delivered: boolean;
  permanent: boolean;
  retryable: boolean;
};

const keys = {
  anonymousId: 'notifie.anonymous_id',
  queue: 'notifie.event_queue',
  userId: 'notifie.user_id',
  pendingIdentify: 'notifie.pending_identify',
  pushToken: 'notifie.push_token',
  lastPushRegistration: 'notifie.last_push_registration',
  pendingRevocations: 'notifie.pending_push_revocations',
  pushSuspended: 'notifie.push_suspended',
  notificationsEnabled: 'notifie.notifications_enabled',
} as const;

const eventNamePattern = /^[A-Za-z0-9][A-Za-z0-9 _.:-]*$/;
const maxBatchSize = 100;
const maxEventPayloadBytes = 900_000;
const maxBackoffMs = 300_000;

export class NotifieClient {
  private readonly storage: NotifieStorage;
  private readonly batchSize: number;
  private readonly maxQueueSize: number;
  private readonly flushIntervalMs: number;
  private readonly retryBaseMs: number;
  private readonly requestTimeoutMs: number;
  private readonly autoFlushOnStart: boolean;
  private readonly now: () => Date;
  private readonly messageIdFactory: () => string;
  private readonly onNotificationReceived?: (notification: NotifieNotification) => void;
  private readonly onNotificationOpened?: (notification: NotifieNotification) => void;
  private readonly onError?: (error: unknown) => void;
  private readonly events: QueuedEvent[] = [];
  private readonly inFlightEventIds = new Set<string>();
  private readonly revocations: string[] = [];
  private userId: string | undefined;
  private pendingIdentify: Record<string, unknown> | undefined;
  private pushRegistration: PushRegistration | undefined;
  private pushSuspended = false;
  private notificationsEnabled = false;
  private lastPushRegistration: string | undefined;
  private startPromise: Promise<void> | undefined;
  private flushPromise: Promise<void> | undefined;
  private queuePersistence: Promise<void> = Promise.resolve();
  private stateOperation: Promise<void> = Promise.resolve();
  private flushTimer: ReturnType<typeof setInterval> | undefined;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private retryAt = 0;
  private retryCountValue = 0;
  private pushAttached = false;
  private subscriptions: Array<() => void> = [];
  private closed = false;

  constructor(
    private readonly apiKey: string,
    private readonly baseUrl: string,
    private anonymousIdValue: string,
    private readonly pushTokenProvider: PushTokenProvider,
    private readonly request: NotifieFetch,
    options: NotifieClientOptions = {},
  ) {
    if (!apiKey.trim()) throw new Error('API key cannot be empty.');
    this.storage = options.storage ?? new MemoryStorage();
    this.batchSize = options.batchSize ?? 20;
    this.maxQueueSize = options.maxQueueSize ?? 1000;
    this.flushIntervalMs = options.flushIntervalMs ?? 30_000;
    this.retryBaseMs = options.retryBaseMs ?? 1000;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 15_000;
    this.autoFlushOnStart = options.autoFlushOnStart ?? true;
    this.now = options.now ?? (() => new Date());
    this.messageIdFactory = options.messageIdFactory ?? createUuid;
    this.onNotificationReceived = options.onNotificationReceived;
    this.onNotificationOpened = options.onNotificationOpened;
    this.onError = options.onError;

    if (this.batchSize < 1 || this.batchSize > maxBatchSize) {
      throw new Error('batchSize must be between 1 and 100.');
    }
    if (this.maxQueueSize < this.batchSize) {
      throw new Error('maxQueueSize must be greater than or equal to batchSize.');
    }
    if (this.requestTimeoutMs < 1) {
      throw new Error('requestTimeoutMs must be greater than zero.');
    }
  }

  get anonymousId(): string {
    return this.anonymousIdValue;
  }

  get currentUserId(): string | undefined {
    return this.userId;
  }

  get pendingEventCount(): number {
    return this.events.length;
  }

  get retryCount(): number {
    return this.retryCountValue;
  }

  start(): Promise<void> {
    this.startPromise ??= this.load();
    return this.startPromise;
  }

  private async load(): Promise<void> {
    await this.storage.setItem(keys.anonymousId, this.anonymousIdValue);
    this.userId = (await this.storage.getItem(keys.userId)) ?? undefined;
    this.events.push(...parseObjectArray<QueuedEvent>(await this.storage.getItem(keys.queue)));
    this.pendingIdentify = parseObject(await this.storage.getItem(keys.pendingIdentify));
    this.pushRegistration = parseObject(
      await this.storage.getItem(keys.pushToken),
    ) as PushRegistration | undefined;
    this.lastPushRegistration =
      (await this.storage.getItem(keys.lastPushRegistration)) ?? undefined;
    this.revocations.push(...parseStringArray(await this.storage.getItem(keys.pendingRevocations)));
    this.pushSuspended = (await this.storage.getItem(keys.pushSuspended)) === 'true';
    this.notificationsEnabled =
      (await this.storage.getItem(keys.notificationsEnabled)) === 'true';
    await this.attachPushProvider(true);

    if (this.flushIntervalMs > 0) {
      this.flushTimer = setInterval(
        () => this.runDetached(this.flush()),
        this.flushIntervalMs,
      );
    }
    if (this.autoFlushOnStart) {
      void Promise.resolve().then(() => this.runDetached(this.flush()));
    }
  }

  async identify(userId: string, properties: NotifieProperties = {}): Promise<void> {
    await this.start();
    if (!userId.trim() || userId.length > 256) {
      throw new Error('userId must contain 1-256 characters.');
    }
    validateProperties(properties);
    await this.serializeState(async () => {
      this.userId = userId;
      await this.storage.setItem(keys.userId, userId);
      this.pendingIdentify = {
        userId,
        anonymousId: this.anonymousIdValue,
        properties,
        timestamp: this.timestamp(),
      };
      await this.storage.setItem(keys.pendingIdentify, JSON.stringify(this.pendingIdentify));
      this.lastPushRegistration = undefined;
      this.pushSuspended = false;
      await Promise.all([
        this.storage.removeItem(keys.lastPushRegistration),
        this.storage.removeItem(keys.pushSuspended),
      ]);
      await this.flush();
    });
  }

  async track(eventName: string, properties: NotifieProperties = {}): Promise<void> {
    await this.start();
    validateEventName(eventName);
    validateProperties(properties);
    await this.serializeState(async () => {
      const event: QueuedEvent = {
        messageId: this.messageIdFactory(),
        anonymousId: this.anonymousIdValue,
        ...(this.userId ? { userId: this.userId } : {}),
        event: eventName,
        timestamp: this.timestamp(),
        properties,
      };
      this.events.push(event);
      while (this.events.length > this.maxQueueSize) {
        const dropIndex = this.events.findIndex(
          (item) => !this.inFlightEventIds.has(item.messageId),
        );
        if (dropIndex < 0) break;
        this.events.splice(dropIndex, 1);
        this.reportError(
          new Error(
            'Event queue is full; dropped the oldest event not currently in flight.',
          ),
        );
      }
      await this.persistQueue();
    });
    if (this.events.length >= this.batchSize) this.runDetached(this.flush());
  }

  async enableNotifications(): Promise<void> {
    await this.start();
    await this.attachPushProvider();
    const registration = await this.pushTokenProvider.enableNotifications();
    if (registration) {
      this.notificationsEnabled = true;
      await this.storage.setItem(keys.notificationsEnabled, 'true');
      await this.registerPushToken(registration);
    } else {
      this.notificationsEnabled = false;
      await this.storage.removeItem(keys.notificationsEnabled);
    }
  }

  async registerPushToken(registration: PushRegistration): Promise<void> {
    await this.start();
    if (!registration.token.trim() || registration.token.length > 512) {
      throw new Error('Push tokens must contain 1-512 characters.');
    }
    await this.serializeState(async () => {
      this.pushRegistration = registration;
      this.lastPushRegistration = undefined;
      await Promise.all([
        this.storage.setItem(keys.pushToken, JSON.stringify(registration)),
        this.storage.removeItem(keys.lastPushRegistration),
      ]);
      await this.flush();
    });
  }

  private async attachPushProvider(ignoreUnavailable = false): Promise<void> {
    if (this.pushAttached) return;
    this.pushAttached = true;
    const attached: Array<() => void> = [];
    try {
      const tokenUnsubscribe = this.pushTokenProvider.subscribeToTokenRefresh?.(
        (registration) => {
          if (this.notificationsEnabled) {
            this.runDetached(this.registerPushToken(registration));
          }
        },
      );
      const receivedUnsubscribe =
        this.pushTokenProvider.subscribeToForegroundNotifications?.(
          (notification) =>
            this.runDetached(this.recordNotificationReceived(notification)),
        );
      const openedUnsubscribe = this.pushTokenProvider.subscribeToOpenedNotifications?.(
        (notification) => this.runDetached(this.recordNotificationOpened(notification)),
      );
      attached.push(
        ...[tokenUnsubscribe, receivedUnsubscribe, openedUnsubscribe].filter(
          (unsubscribe): unsubscribe is () => void => Boolean(unsubscribe),
        ),
      );
      const initial = await this.pushTokenProvider.getInitialNotification?.();
      this.subscriptions.push(...attached);
      if (initial) await this.recordInitialNotification(initial);
    } catch (error) {
      for (const unsubscribe of attached) unsubscribe();
      this.pushAttached = false;
      if (!ignoreUnavailable) throw error;
      this.reportError(error);
    }
  }

  async flush(): Promise<void> {
    await this.start();
    if (this.flushPromise) {
      await this.flushPromise;
      if (this.hasPendingDelivery()) await this.flush();
      return;
    }
    const operation = this.drain();
    this.flushPromise = operation;
    try {
      await operation;
    } finally {
      if (this.flushPromise === operation) this.flushPromise = undefined;
    }
  }

  private async drain(): Promise<void> {
    if (this.closed || this.retryAt > this.now().getTime()) return;
    if (!(await this.flushRevocations())) return;
    await this.flushEvents();
    await this.flushIdentify();
    await this.flushPushToken();
  }

  private async flushEvents(): Promise<void> {
    while (this.events.length > 0) {
      const batch = this.nextEventBatch();
      const batchIds = new Set(batch.map(event => event.messageId));
      for (const id of batchIds) this.inFlightEventIds.add(id);
      const result = await this.send('POST', '/api/v1/events', {
        events: batch,
        sentAt: this.timestamp(),
      });
      for (const id of batchIds) this.inFlightEventIds.delete(id);
      if (result.retryable) {
        this.scheduleRetry();
        return;
      }
      for (let index = this.events.length - 1; index >= 0; index -= 1) {
        if (batchIds.has(this.events[index]!.messageId)) this.events.splice(index, 1);
      }
      await this.persistQueue();
      this.clearRetry();
    }
  }

  private nextEventBatch(): QueuedEvent[] {
    const candidates = this.events.slice(
      0,
      Math.min(this.batchSize, maxBatchSize),
    );
    const batch: QueuedEvent[] = [];
    for (const event of candidates) {
      const candidate = [...batch, event];
      const body = JSON.stringify({
        events: candidate,
        sentAt: this.timestamp(),
      });
      if (batch.length > 0 && utf8ByteLength(body) > maxEventPayloadBytes) break;
      batch.push(event);
    }
    return batch;
  }

  private async flushIdentify(): Promise<void> {
    while (this.pendingIdentify) {
      const pending = this.pendingIdentify;
      const result = await this.send('POST', '/api/v1/identify', pending);
      if (result.delivered || result.permanent) {
        if (this.pendingIdentify === pending) {
          this.pendingIdentify = undefined;
          await this.storage.removeItem(keys.pendingIdentify);
        }
      } else {
        this.scheduleRetry();
        return;
      }
    }
  }

  private async flushPushToken(): Promise<void> {
    if (this.pushSuspended) return;
    const registration = this.pushRegistration;
    if (!registration) return;
    const fingerprint = `${registration.token}:${this.userId ?? ''}:${this.anonymousIdValue}`;
    if (fingerprint === this.lastPushRegistration) return;
    const result = await this.send('POST', '/api/v1/push-tokens', {
      anonymousId: this.anonymousIdValue,
      ...(this.userId ? { userId: this.userId } : {}),
      ...registration,
    });
    if (result.delivered) {
      if (this.currentPushFingerprint() === fingerprint) {
        this.lastPushRegistration = fingerprint;
        await this.storage.setItem(keys.lastPushRegistration, fingerprint);
      }
    } else if (result.retryable) {
      this.scheduleRetry();
    }
  }

  private currentPushFingerprint(): string | undefined {
    const registration = this.pushRegistration;
    return registration
      ? `${registration.token}:${this.userId ?? ''}:${this.anonymousIdValue}`
      : undefined;
  }

  private hasPendingDelivery(): boolean {
    if (this.closed || this.retryAt > this.now().getTime()) return false;
    return this.events.length > 0
      || Boolean(this.pendingIdentify)
      || this.revocations.length > 0
      || (
        !this.pushSuspended
        && Boolean(this.pushRegistration)
        && this.currentPushFingerprint() !== this.lastPushRegistration
      );
  }

  private async flushRevocations(): Promise<boolean> {
    for (const token of [...this.revocations]) {
      const result = await this.send('DELETE', '/api/v1/push-tokens', { token });
      if (!result.delivered && !(result.permanent && [400, 413].includes(result.status))) {
        if (result.retryable) this.scheduleRetry();
        return false;
      }
      const index = this.revocations.indexOf(token);
      if (index >= 0) this.revocations.splice(index, 1);
      await this.persistRevocations();
    }
    return this.revocations.length === 0;
  }

  async reset(): Promise<void> {
    await this.start();
    await this.serializeState(async () => {
      if (this.flushPromise) await this.flushPromise;
      await this.queuePersistence;
      const token = this.pushRegistration?.token;
      if (token && !this.revocations.includes(token)) {
        this.revocations.push(token);
        await this.persistRevocations();
      }
      // Logout revocation is safety-critical and must not wait behind an
      // unrelated event retry window.
      this.clearRetry();
      this.events.splice(0);
      this.pendingIdentify = undefined;
      this.lastPushRegistration = undefined;
      this.pushSuspended = true;
      this.userId = undefined;
      this.anonymousIdValue = this.messageIdFactory();
      await Promise.all([
        this.storage.setItem(keys.anonymousId, this.anonymousIdValue),
        this.storage.removeItem(keys.queue),
        this.storage.removeItem(keys.pendingIdentify),
        this.storage.removeItem(keys.lastPushRegistration),
        this.storage.removeItem(keys.userId),
        this.storage.setItem(keys.pushSuspended, 'true'),
      ]);
      await this.flush();
    });
  }

  async close(): Promise<void> {
    this.closed = true;
    if (this.flushTimer) clearInterval(this.flushTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    for (const unsubscribe of this.subscriptions.splice(0)) unsubscribe();
    if (this.flushPromise) await this.flushPromise;
  }

  async recordNotificationReceived(
    notification: NotifieNotification,
  ): Promise<void> {
    await this.track('notification_received', notificationProperties(notification));
    try {
      this.onNotificationReceived?.(notification);
    } catch (error) {
      this.reportError(error);
    }
  }

  async recordNotificationOpened(
    notification: NotifieNotification,
  ): Promise<void> {
    await this.track('notification_opened', notificationProperties(notification));
    try {
      this.onNotificationOpened?.(notification);
    } catch (error) {
      this.reportError(error);
    }
  }

  private async recordInitialNotification(
    notification: NotifieNotification,
  ): Promise<void> {
    await this.serializeState(async () => {
      const event: QueuedEvent = {
        messageId: this.messageIdFactory(),
        anonymousId: this.anonymousIdValue,
        ...(this.userId ? { userId: this.userId } : {}),
        event: 'notification_opened',
        timestamp: this.timestamp(),
        properties: notificationProperties(notification),
      };
      this.events.push(event);
      await this.persistQueue();
    });
    try {
      this.onNotificationOpened?.(notification);
    } catch (error) {
      this.reportError(error);
    }
  }

  private async send(
    method: 'POST' | 'DELETE',
    path: string,
    body: Record<string, unknown>,
  ): Promise<HttpResult> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.requestTimeoutMs);
    try {
      const response = await this.request(`${this.baseUrl.replace(/\/$/, '')}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      const status = response.status;
      return {
        status,
        delivered: response.ok,
        permanent: status >= 400 && status < 500 && status !== 429,
        retryable: status === 429 || status >= 500,
      };
    } catch {
      return { status: 0, delivered: false, permanent: false, retryable: true };
    } finally {
      clearTimeout(timeout);
    }
  }

  private scheduleRetry(): void {
    if (this.closed) return;
    if (this.retryTimer) return;
    this.retryCountValue += 1;
    const base = Math.min(
      this.retryBaseMs * 2 ** (this.retryCountValue - 1),
      maxBackoffMs,
    );
    const delay = Math.max(1, Math.round(base * (0.85 + Math.random() * 0.3)));
    this.retryAt = this.now().getTime() + delay;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.retryAt = 0;
      this.runDetached(this.flush());
    }, delay);
  }

  private clearRetry(): void {
    this.retryCountValue = 0;
    this.retryAt = 0;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
  }

  private async persistQueue(): Promise<void> {
    const encoded = this.events.length === 0 ? undefined : JSON.stringify(this.events);
    const operation = this.queuePersistence
      .catch(() => undefined)
      .then(() =>
        encoded === undefined
          ? this.storage.removeItem(keys.queue)
          : this.storage.setItem(keys.queue, encoded),
      );
    this.queuePersistence = operation;
    await operation;
  }

  private async persistRevocations(): Promise<void> {
    if (this.revocations.length === 0) {
      await this.storage.removeItem(keys.pendingRevocations);
    } else {
      await this.storage.setItem(keys.pendingRevocations, JSON.stringify(this.revocations));
    }
  }

  private serializeState(operation: () => Promise<void>): Promise<void> {
    const run = this.stateOperation.then(operation, operation);
    this.stateOperation = run.catch(() => undefined);
    return run;
  }

  private timestamp(): string {
    return this.now().toISOString();
  }

  private runDetached(operation: Promise<void>): void {
    void operation.catch((error: unknown) => this.reportError(error));
  }

  private reportError(error: unknown): void {
    try {
      this.onError?.(error);
    } catch {
      // Host diagnostics must never break SDK lifecycle work.
    }
  }
}

export function notificationFromData(
  data: Record<string, string>,
  title?: string,
  body?: string,
): NotifieNotification {
  return {
    data,
    ...(title ? { title } : {}),
    ...(body ? { body } : {}),
    ...(data.gk_invocation_id ? { invocationId: data.gk_invocation_id } : {}),
    ...(data.gk_deep_link ? { deepLink: data.gk_deep_link } : {}),
    ...(data.gk_image_url ? { imageUrl: data.gk_image_url } : {}),
  };
}

function notificationProperties(notification: NotifieNotification): NotifieProperties {
  return notification.invocationId ? { invocation_id: notification.invocationId } : {};
}

function validateEventName(eventName: string): void {
  if (!eventName || eventName.length > 64 || !eventNamePattern.test(eventName)) {
    throw new Error(
      'Event name must start alphanumeric, be at most 64 characters, and contain only letters, numbers, spaces, _ . : -.',
    );
  }

}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      bytes += 4;
      index += 1;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function validateProperties(properties: NotifieProperties): void {
  const entries = Object.entries(properties);
  if (entries.length > 64) throw new Error('At most 64 properties are allowed.');
  for (const [key, value] of entries) {
    if (!key || key.length > 128) {
      throw new Error('Property keys must contain 1-128 characters.');
    }
    if (
      value !== null &&
      typeof value !== 'string' &&
      typeof value !== 'number' &&
      typeof value !== 'boolean'
    ) {
      throw new Error('Properties must be flat string, number, boolean, or null values.');
    }
    if (typeof value === 'string' && value.length > 1024) {
      throw new Error('String property values must be at most 1024 characters.');
    }
    if (typeof value === 'number' && !Number.isFinite(value)) {
      throw new Error('Number properties must be finite.');
    }
  }
}

function parseObject(value: string | null): Record<string, unknown> | undefined {
  if (!value) return undefined;
  try {
    const parsed: unknown = JSON.parse(value);
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : undefined;
  } catch {
    return undefined;
  }
}

function parseObjectArray<T extends object>(value: string | null): T[] {
  if (!value) return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is T => item !== null && typeof item === 'object')
      : [];
  } catch {
    return [];
  }
}

function parseStringArray(value: string | null): string[] {
  if (!value) return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : [];
  } catch {
    return [];
  }
}

export function createUuid(): string {
  const bytes = Array.from({ length: 16 }, () => Math.floor(Math.random() * 256));
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

class MemoryStorage implements NotifieStorage {
  private readonly values = new Map<string, string>();

  async getItem(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }

  async setItem(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async removeItem(key: string): Promise<void> {
    this.values.delete(key);
  }
}
