import { describe, expect, it, vi } from 'vitest';
import {
  NotifieClient,
  type NotifieFetch,
  type NotifieNotification,
  type NotifieStorage,
  type PushRegistration,
  type PushTokenProvider,
} from '../src/client.ts';

const stableId = '11111111-1111-4111-8111-111111111111';

describe('NotifieClient', () => {
  it('persists a queued event and reuses its message ID after retry', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    let status = 503;
    const storage = new TestStorage();
    const request = vi.fn<NotifieFetch>(async (_input, init) => {
      bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return new Response(null, { status });
    });
    const client = createClient({ storage, request });

    await client.start();
    await client.track('notification_requested', { source: 'button' });
    await client.flush();

    expect(client.pendingEventCount).toBe(1);
    expect(client.retryCount).toBe(1);
    expect(storage.values.get('notifie.event_queue')).toBeDefined();

    status = 202;
    await new Promise((resolve) => setTimeout(resolve, 10));
    await client.flush();

    const first = (bodies[0]?.events as Array<Record<string, unknown>>)[0];
    const retried = (bodies.at(-1)?.events as Array<Record<string, unknown>>)[0];
    expect(first?.messageId).toBe(stableId);
    expect(retried?.messageId).toBe(first?.messageId);
    expect(client.pendingEventCount).toBe(0);
    expect(storage.values.has('notifie.event_queue')).toBe(false);
    await client.close();
  });

  it('restores a persisted queue after restart', async () => {
    const storage = new TestStorage();
    const offline = createClient({
      storage,
      request: async () => new Response(null, { status: 503 }),
    });
    await offline.start();
    await offline.track('offline_event');
    await offline.close();

    let sent: Record<string, unknown> | undefined;
    const restarted = createClient({
      storage,
      request: async (_input, init) => {
        sent = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response(null, { status: 202 });
      },
    });
    await restarted.start();
    expect(restarted.pendingEventCount).toBe(1);
    await restarted.flush();

    const event = (sent?.events as Array<Record<string, unknown>>)[0];
    expect(event).toMatchObject({ event: 'offline_event', messageId: stableId });
    await restarted.close();
  });

  it('respects batchSize and splits payloads below the ingest byte limit', async () => {
    const requestBodies: string[] = [];
    let messageId = 0;
    const client = createClient({
      storage: new TestStorage(),
      batchSize: 20,
      messageIdFactory: () => {
        messageId += 1;
        return `00000000-0000-4000-8000-${String(messageId).padStart(12, '0')}`;
      },
      request: async (_input, init) => {
        requestBodies.push(String(init?.body));
        return new Response(null, { status: 202 });
      },
    });
    await client.start();
    const properties = Object.fromEntries(
      Array.from({ length: 64 }, (_, index) => [
        `property_${index}_${'k'.repeat(100)}`,
        'v'.repeat(1024),
      ]),
    );

    for (let index = 0; index < 20; index += 1) {
      await client.track(`large_event_${index}`, properties);
    }
    await client.flush();

    expect(requestBodies.length).toBeGreaterThan(1);
    expect(requestBodies.every(body => new TextEncoder().encode(body).byteLength <= 900_000))
      .toBe(true);
    const sentEvents = requestBodies.reduce((total, body) => {
      const parsed = JSON.parse(body) as { events: unknown[] };
      expect(parsed.events.length).toBeLessThanOrEqual(20);
      return total + parsed.events.length;
    }, 0);
    expect(sentEvents).toBe(20);
    await client.close();
  });

  it('identifies before registering the stored push token for that user', async () => {
    const calls: Array<{ path: string; body: Record<string, unknown> }> = [];
    const provider = new TestPushProvider({
      token: 'fcm-token',
      platform: 'android',
      provider: 'fcm',
    });
    const client = createClient({
      storage: new TestStorage(),
      provider,
      request: async (input, init) => {
        calls.push({
          path: new URL(String(input)).pathname,
          body: JSON.parse(String(init?.body)) as Record<string, unknown>,
        });
        return new Response(null, { status: 202 });
      },
    });

    await client.start();
    await client.enableNotifications();
    calls.splice(0);
    await client.identify('user-7', { plan: 'pro' });

    expect(calls.map((call) => call.path)).toEqual([
      '/api/v1/identify',
      '/api/v1/push-tokens',
    ]);
    expect(calls[0]?.body.userId).toBe('user-7');
    expect(calls[1]?.body.userId).toBe('user-7');
    await client.close();
  });

  it('revokes push token and rotates anonymous identity on reset', async () => {
    const calls: Array<{ method: string; path: string }> = [];
    let nextId = 0;
    const storage = new TestStorage();
    const client = createClient({
      storage,
      provider: new TestPushProvider({
        token: 'fcm-token',
        platform: 'ios',
        provider: 'fcm',
      }),
      messageIdFactory: () => {
        nextId += 1;
        return nextId === 1
          ? stableId
          : '22222222-2222-4222-8222-222222222222';
      },
      request: async (input, init) => {
        calls.push({ method: String(init?.method), path: new URL(String(input)).pathname });
        return new Response(null, { status: 202 });
      },
    });

    await client.start();
    const originalId = client.anonymousId;
    await client.enableNotifications();
    await client.reset();

    expect(calls.at(-1)).toEqual({ method: 'DELETE', path: '/api/v1/push-tokens' });
    expect(client.currentUserId).toBeUndefined();
    expect(client.anonymousId).not.toBe(originalId);
    expect(storage.values.has('notifie.push_token')).toBe(true);
    expect(storage.values.get('notifie.push_suspended')).toBe('true');
    await client.close();
  });

  it('retains refreshed token while logged out and restores it on identify', async () => {
    const calls: Array<{
      method: string;
      path: string;
      body: Record<string, unknown>;
    }> = [];
    const provider = new TestPushProvider({
      token: 'token-before-reset',
      platform: 'ios',
      provider: 'fcm',
    });
    const client = createClient({
      storage: new TestStorage(),
      provider,
      request: async (input, init) => {
        calls.push({
          method: String(init?.method),
          path: new URL(String(input)).pathname,
          body: JSON.parse(String(init?.body)) as Record<string, unknown>,
        });
        return new Response(null, { status: 202 });
      },
    });
    await client.start();
    await client.enableNotifications();
    await client.reset();
    const callsAfterReset = calls.length;

    provider.emitToken({
      token: 'token-after-reset',
      platform: 'ios',
      provider: 'fcm',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await client.flush();
    expect(calls.slice(callsAfterReset)).toEqual([]);

    await client.identify('next-user');
    const registration = calls.at(-1);
    expect(registration).toMatchObject({
      method: 'POST',
      path: '/api/v1/push-tokens',
      body: {
        token: 'token-after-reset',
        userId: 'next-user',
      },
    });
    await client.close();
  });

  it('tracks notification engagement and forwards host callbacks', async () => {
    const events: string[] = [];
    let opened: NotifieNotification | undefined;
    const provider = new TestPushProvider(null);
    const client = createClient({
      storage: new TestStorage(),
      provider,
      onNotificationOpened: (notification) => {
        opened = notification;
      },
      request: async (_input, init) => {
        const body = JSON.parse(String(init?.body)) as {
          events?: Array<{ event: string }>;
        };
        events.push(...(body.events ?? []).map((event) => event.event));
        return new Response(null, { status: 202 });
      },
    });

    await client.start();
    provider.emitOpened({
      data: {
        gk_invocation_id: 'inv-9',
        gk_deep_link: 'myapp://posts/7',
      },
      invocationId: 'inv-9',
      deepLink: 'myapp://posts/7',
    });
    await Promise.resolve();
    await client.flush();

    expect(events).toContain('notification_opened');
    expect(opened).toMatchObject({ invocationId: 'inv-9', deepLink: 'myapp://posts/7' });
    await client.close();
  });

  it('does not register refreshed tokens before notification opt-in', async () => {
    const pushTokens: string[] = [];
    const provider = new TestPushProvider({
      token: 'enabled-token',
      platform: 'android',
      provider: 'fcm',
    });
    const client = createClient({
      storage: new TestStorage(),
      provider,
      request: async (input, init) => {
        if (
          new URL(String(input)).pathname === '/api/v1/push-tokens'
          && init?.method === 'POST'
        ) {
          const body = JSON.parse(String(init.body)) as { token: string };
          pushTokens.push(body.token);
        }
        return new Response(null, { status: 202 });
      },
    });
    await client.start();

    provider.emitToken({
      token: 'pre-opt-in-token',
      platform: 'android',
      provider: 'fcm',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(pushTokens).toEqual([]);

    await client.enableNotifications();
    provider.emitToken({
      token: 'refreshed-token',
      platform: 'android',
      provider: 'fcm',
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await client.flush();
    expect(pushTokens).toEqual(['enabled-token', 'refreshed-token']);
    await client.close();
  });

  it('serializes concurrent identify calls without losing the newer identity', async () => {
    let releaseFirst: (() => void) | undefined;
    let markFirstStarted: (() => void) | undefined;
    const firstStarted = new Promise<void>((resolve) => {
      markFirstStarted = resolve;
    });
    const firstResponse = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const identified: string[] = [];
    const storage = new TestStorage();
    const client = createClient({
      storage,
      request: async (input, init) => {
        if (new URL(String(input)).pathname === '/api/v1/identify') {
          const body = JSON.parse(String(init?.body)) as { userId: string };
          identified.push(body.userId);
          if (identified.length === 1) {
            markFirstStarted?.();
            await firstResponse;
          }
        }
        return new Response(null, { status: 202 });
      },
    });
    await client.start();

    const first = client.identify('user-first');
    await firstStarted;
    const second = client.identify('user-second');
    releaseFirst?.();
    await Promise.all([first, second]);

    expect(identified).toEqual(['user-first', 'user-second']);
    expect(client.currentUserId).toBe('user-second');
    expect(storage.values.get('notifie.user_id')).toBe('user-second');
    await client.close();
  });

  it('does not let an in-flight identify resurrect state after reset', async () => {
    let releaseIdentify: (() => void) | undefined;
    let markIdentifyStarted: (() => void) | undefined;
    const identifyStarted = new Promise<void>((resolve) => {
      markIdentifyStarted = resolve;
    });
    const identifyResponse = new Promise<void>((resolve) => {
      releaseIdentify = resolve;
    });
    const storage = new TestStorage();
    const client = createClient({
      storage,
      request: async (input) => {
        if (new URL(String(input)).pathname === '/api/v1/identify') {
          markIdentifyStarted?.();
          await identifyResponse;
        }
        return new Response(null, { status: 202 });
      },
    });
    await client.start();

    const identify = client.identify('logged-out-user');
    await identifyStarted;
    const reset = client.reset();
    releaseIdentify?.();
    await Promise.all([identify, reset]);

    expect(client.currentUserId).toBeUndefined();
    expect(storage.values.has('notifie.user_id')).toBe(false);
    expect(storage.values.has('notifie.pending_identify')).toBe(false);
    await client.close();
  });

  it('retries revocation before re-registering the same provider token', async () => {
    const methods: string[] = [];
    let deleteAttempts = 0;
    const provider = new TestPushProvider({
      token: 'reused-token',
      platform: 'android',
      provider: 'fcm',
    });
    const client = createClient({
      storage: new TestStorage(),
      provider,
      request: async (input, init) => {
        const path = new URL(String(input)).pathname;
        if (path === '/api/v1/push-tokens') {
          const method = String(init?.method);
          methods.push(method);
          if (method === 'DELETE') {
            deleteAttempts += 1;
            if (deleteAttempts === 1) return new Response(null, { status: 503 });
          }
        }
        return new Response(null, { status: 202 });
      },
    });
    await client.start();
    await client.enableNotifications();

    await client.reset();
    await client.registerPushToken({
      token: 'reused-token',
      platform: 'android',
      provider: 'fcm',
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    await client.flush();
    expect(methods).toEqual(['POST', 'DELETE', 'DELETE']);

    await client.identify('next-user');
    expect(methods).toEqual(['POST', 'DELETE', 'DELETE', 'POST']);
    await client.close();
  });

  it('does not delay logout revocation behind an event retry backoff', async () => {
    const calls: Array<{ method: string; path: string }> = [];
    const client = createClient({
      storage: new TestStorage(),
      retryBaseMs: 300_000,
      provider: new TestPushProvider({
        token: 'logout-token',
        platform: 'android',
        provider: 'fcm',
      }),
      request: async (input, init) => {
        const call = {
          method: String(init?.method),
          path: new URL(String(input)).pathname,
        };
        calls.push(call);
        return new Response(null, {
          status: call.path === '/api/v1/events' ? 503 : 202,
        });
      },
    });
    await client.start();
    await client.enableNotifications();
    await client.track('offline_event');
    await client.flush();
    expect(client.retryCount).toBe(1);

    await client.reset();

    expect(calls.at(-1)).toEqual({
      method: 'DELETE',
      path: '/api/v1/push-tokens',
    });
    await client.close();
  });

  it('waits for an in-flight flush before reset clears the queue', async () => {
    let resolveResponse: ((response: Response) => void) | undefined;
    let markRequestStarted: (() => void) | undefined;
    const requestStarted = new Promise<void>((resolve) => {
      markRequestStarted = resolve;
    });
    const client = createClient({
      storage: new TestStorage(),
      request: async () =>
        new Promise<Response>((resolve) => {
          resolveResponse = resolve;
          markRequestStarted?.();
        }),
    });
    await client.start();
    await client.track('in_flight_event');

    const flush = client.flush();
  await requestStarted;
    const reset = client.reset();
    expect(client.pendingEventCount).toBe(1);

    resolveResponse?.(new Response(null, { status: 202 }));
    await flush;
    await reset;

    expect(client.pendingEventCount).toBe(0);
    await client.close();
  });

  it('rejects nested properties before enqueueing', async () => {
    const client = createClient({
      storage: new TestStorage(),
      request: async () => new Response(null, { status: 202 }),
    });
    await client.start();

    await expect(
      client.track('invalid', { nested: { no: true } } as never),
    ).rejects.toThrow(/flat/);
    expect(client.pendingEventCount).toBe(0);
    await client.close();
  });
});

function createClient({
  storage,
  request,
  provider = new TestPushProvider(null),
  messageIdFactory = () => stableId,
  retryBaseMs = 1,
  batchSize = 20,
  onNotificationOpened,
}: {
  storage: NotifieStorage;
  request: NotifieFetch;
  provider?: PushTokenProvider;
  messageIdFactory?: () => string;
  retryBaseMs?: number;
  batchSize?: number;
  onNotificationOpened?: (notification: NotifieNotification) => void;
}): NotifieClient {
  return new NotifieClient(
    'sdk_test_key',
    'https://notifie.example',
    'device-123',
    provider,
    request,
    {
      storage,
      batchSize,
      flushIntervalMs: 0,
      retryBaseMs,
      autoFlushOnStart: false,
      messageIdFactory,
      onNotificationOpened,
    },
  );
}

class TestStorage implements NotifieStorage {
  readonly values = new Map<string, string>();

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

class TestPushProvider implements PushTokenProvider {
  private openedListener: ((notification: NotifieNotification) => void) | undefined;
  private tokenListener: ((registration: PushRegistration) => void) | undefined;

  constructor(private readonly registration: PushRegistration | null) {}

  async enableNotifications(): Promise<PushRegistration | null> {
    return this.registration;
  }

  subscribeToOpenedNotifications(
    listener: (notification: NotifieNotification) => void,
  ): () => void {
    this.openedListener = listener;
    return () => {
      this.openedListener = undefined;
    };
  }

  subscribeToTokenRefresh(
    listener: (registration: PushRegistration) => void,
  ): () => void {
    this.tokenListener = listener;
    return () => {
      this.tokenListener = undefined;
    };
  }

  emitOpened(notification: NotifieNotification): void {
    this.openedListener?.(notification);
  }

  emitToken(registration: PushRegistration): void {
    this.tokenListener?.(registration);
  }
}
