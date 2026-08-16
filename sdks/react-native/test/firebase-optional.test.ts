import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  values: new Map<string, string>(),
  requests: [] as Array<{ path: string; body: Record<string, unknown> }>,
}));

vi.mock('@react-native-async-storage/async-storage', () => ({
  default: {
    getItem: async (key: string) => state.values.get(key) ?? null,
    setItem: async (key: string, value: string) => {
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
  default: () => {
    throw new Error("No Firebase App '[DEFAULT]' has been created");
  },
}));

vi.mock('react-native', () => ({
  AppState: {
    currentState: 'active',
    addEventListener: () => ({ remove() {} }),
  },
  PermissionsAndroid: {
    PERMISSIONS: { POST_NOTIFICATIONS: 'android.permission.POST_NOTIFICATIONS' },
    RESULTS: { GRANTED: 'granted' },
    request: async () => 'granted',
  },
  Platform: { OS: 'ios', Version: '26.5' },
}));

describe('React Native event-only setup', () => {
  beforeEach(() => {
    state.values.clear();
    state.requests.length = 0;
    vi.resetModules();
    vi.stubGlobal('fetch', vi.fn(async (input: string | Request, init?: RequestInit) => {
      state.requests.push({
        path: new URL(String(input)).pathname,
        body: JSON.parse(String(init?.body)) as Record<string, unknown>,
      });
      return new Response(null, { status: 202 });
    }));
  });

  it('initializes and tracks without a configured Firebase app', async () => {
    const { Notifie } = await import('../src/index.ts');
    expect(Notifie).toBeDefined();

    await Notifie.initialize({
      apiKey: 'sdk_test_key',
      baseUrl: 'https://notifie.example',
      flushIntervalMs: 0,
    });
    await Notifie.track('event_only');
    await Notifie.flush();

    const eventNames = state.requests.flatMap((request) => {
      const events = request.body.events;
      return Array.isArray(events)
        ? events.map((event) => (event as { event: string }).event)
        : [];
    });
    expect(eventNames).toContain('event_only');
    await expect(Notifie.enableNotifications()).rejects.toThrow(
      'Firebase Messaging is not configured',
    );
  });
});