import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { NotifieNotification } from '../src/client.ts';

const state = vi.hoisted(() => ({
  values: new Map<string, string>(),
  failQueueWrites: false,
  failBackgroundWrites: false,
  appStateListener: undefined as ((state: string) => void) | undefined,
  currentAppState: 'active',
  backgroundHandler: undefined as
    | ((message: { messageId?: string; data?: Record<string, string> }) => Promise<void>)
    | undefined,
}));

vi.mock('@react-native-async-storage/async-storage', () => ({
  default: {
    getItem: async (key: string) => state.values.get(key) ?? null,
    setItem: async (key: string, value: string) => {
      if (
        state.failBackgroundWrites
        && key.startsWith('notifie.pending_background_notification.')
      ) {
        throw new Error('background storage unavailable');
      }
      if (state.failQueueWrites && key === 'notifie.event_queue') {
        throw new Error('storage unavailable');
      }
      state.values.set(key, value);
    },
    removeItem: async (key: string) => {
      state.values.delete(key);
    },
    getAllKeys: async () => [...state.values.keys()],
  },
}));

vi.mock('@react-native-firebase/messaging', () => ({
  AuthorizationStatus: { AUTHORIZED: 1, PROVISIONAL: 2 },
  default: () => ({
    setBackgroundMessageHandler(
      handler: (message: {
        messageId?: string;
        data?: Record<string, string>;
      }) => Promise<void>,
    ) {
      state.backgroundHandler = handler;
    },
    onTokenRefresh: () => () => undefined,
    onMessage: () => () => undefined,
    onNotificationOpenedApp: () => () => undefined,
    getInitialNotification: async () => null,
    requestPermission: async () => 1,
    getToken: async () => null,
  }),
}));

vi.mock('react-native', () => ({
  AppState: {
    get currentState() {
      return state.currentAppState;
    },
    addEventListener: (_event: string, listener: (nextState: string) => void) => {
      state.appStateListener = listener;
      return { remove() { state.appStateListener = undefined; } };
    },
  },
  PermissionsAndroid: {
    PERMISSIONS: { POST_NOTIFICATIONS: 'android.permission.POST_NOTIFICATIONS' },
    RESULTS: { GRANTED: 'granted' },
    request: async () => 'granted',
  },
  Platform: { OS: 'android', Version: 36 },
}));

describe('React Native background notifications', () => {
  beforeEach(() => {
    state.values.clear();
    state.failQueueWrites = false;
    state.failBackgroundWrites = false;
    state.appStateListener = undefined;
    state.currentAppState = 'active';
    state.backgroundHandler = undefined;
    vi.resetModules();
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 202 })));
  });

  it('persists concurrent headless messages and replays each once', async () => {
    const { Notifie } = await import('../src/index.ts');
    expect(state.backgroundHandler).toBeTypeOf('function');
    await Promise.all([
      state.backgroundHandler?.({
        messageId: 'message-1',
        data: {
          gk_invocation_id: 'inv-background-1',
          refresh: 'true',
        },
      }),
      state.backgroundHandler?.({
        messageId: 'message-2',
        data: {
          gk_invocation_id: 'inv-background-2',
          refresh: 'true',
        },
      }),
    ]);

    expect(
      [...state.values.keys()].filter(key =>
        key.startsWith('notifie.pending_background_notification.'),
      ),
    ).toHaveLength(2);

    const received: NotifieNotification[] = [];
    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
      onNotificationReceived(notification) {
        received.push(notification);
      },
    });

    expect(received.map(notification => notification.invocationId)).toEqual([
      'inv-background-1',
      'inv-background-2',
    ]);
    expect(
      [...state.values.keys()].some(key =>
        key.startsWith('notifie.pending_background_notification.'),
      ),
    ).toBe(false);
  });

  it('acknowledges a background record only after durable event persistence', async () => {
    const { Notifie } = await import('../src/index.ts');
    await state.backgroundHandler?.({
      messageId: 'message-durable',
      data: { gk_invocation_id: 'inv-durable' },
    });
    const pendingKey = [...state.values.keys()].find(key =>
      key.startsWith('notifie.pending_background_notification.'),
    );
    expect(pendingKey).toBeDefined();

    state.failQueueWrites = true;
    await expect(Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
    })).rejects.toThrow('storage unavailable');
    expect(state.values.has(pendingKey!)).toBe(true);

    state.failQueueWrites = false;
    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
      onNotificationReceived() {
        throw new Error('host callback failed');
      },
    });
    expect(state.values.has(pendingKey!)).toBe(false);
  });

  it('does not let one failed headless write poison later initialization', async () => {
    const { Notifie } = await import('../src/index.ts');
    state.failBackgroundWrites = true;
    await state.backgroundHandler?.({
      messageId: 'message-failed-write',
      data: { gk_invocation_id: 'inv-failed-write' },
    });
    state.failBackgroundWrites = false;

    await expect(Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
    })).resolves.toBeUndefined();
  });

  it('starts a new session only after the app actually backgrounded', async () => {
    const { Notifie } = await import('../src/index.ts');
    const request = vi.mocked(fetch);
    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
    });
    await Notifie.flush();
    request.mockClear();

    state.appStateListener?.('inactive');
    state.appStateListener?.('active');
    await Notifie.flush();
    expect(request).not.toHaveBeenCalled();

    state.appStateListener?.('background');
    state.appStateListener?.('inactive');
    state.appStateListener?.('active');
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Notifie.flush();

    const events = request.mock.calls.flatMap(([, init]) => {
      const body = JSON.parse(String(init?.body)) as {
        events?: Array<{ event: string }>;
      };
      return body.events?.map(event => event.event) ?? [];
    });
    expect(events.filter(event => event === 'app_open')).toHaveLength(1);
    expect(events.filter(event => event === 'session_start')).toHaveLength(1);
  });

  it('does not emit a foreground session during background-only startup', async () => {
    state.currentAppState = 'background';
    const { Notifie } = await import('../src/index.ts');
    const request = vi.mocked(fetch);

    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
    });
    await Notifie.flush();
    expect(request).not.toHaveBeenCalled();

    state.currentAppState = 'active';
    state.appStateListener?.('active');
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Notifie.flush();

    const events = request.mock.calls.flatMap(([, init]) => {
      const body = JSON.parse(String(init?.body)) as {
        events?: Array<{ event: string }>;
      };
      return body.events?.map(event => event.event) ?? [];
    });
    expect(events).toEqual(['install', 'first_open', 'app_open', 'session_start']);
  });

  it('replays minimized-app background messages on foreground resume', async () => {
    const { Notifie } = await import('../src/index.ts');
    const received: NotifieNotification[] = [];
    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
      onNotificationReceived(notification) {
        received.push(notification);
      },
    });
    await Notifie.flush();

    state.currentAppState = 'background';
    state.appStateListener?.('background');
    await state.backgroundHandler?.({
      messageId: 'message-while-minimized',
      data: { gk_invocation_id: 'inv-while-minimized' },
    });
    expect(received).toEqual([]);

    state.currentAppState = 'active';
    state.appStateListener?.('active');
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Notifie.flush();

    expect(received.map(notification => notification.invocationId))
      .toEqual(['inv-while-minimized']);
    expect(
      [...state.values.keys()].some(key =>
        key.startsWith('notifie.pending_background_notification.'),
      ),
    ).toBe(false);
  });
});
