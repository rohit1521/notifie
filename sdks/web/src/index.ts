import { NotifieClient } from './client.ts';

const anonymousIdKey = 'notifie.anonymous_id';
let client: NotifieClient | null = null;

export const Notifie = {
  initialize({
    apiKey,
    baseUrl = 'https://notifie.dev',
  }: {
    apiKey: string;
    baseUrl?: string;
  }): void {
    if (!apiKey.trim()) throw new Error('API key cannot be empty.');

    client = new NotifieClient(
      apiKey,
      baseUrl,
      loadAnonymousId(),
      fetch,
    );
  },

  track(
    eventName: string,
    properties: Record<string, string | number | boolean | null> = {},
  ): Promise<void> {
    if (!client) throw new Error('Call Notifie.initialize() before using the SDK.');
    return client.track(eventName, properties);
  },
};

function loadAnonymousId(): string {
  const existing = localStorage.getItem(anonymousIdKey);
  if (existing) return existing;

  const generated = crypto.randomUUID();
  localStorage.setItem(anonymousIdKey, generated);
  return generated;
}