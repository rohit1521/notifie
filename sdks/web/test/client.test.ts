import { describe, expect, it, vi } from 'vitest';
import { NotifieClient, type NotifieFetch } from '../src/client.ts';
import { Notifie } from '../src/index.ts';

describe('NotifieClient', () => {
  it('tracks an event with hidden identity and transport details', async () => {
    const request = vi.fn<NotifieFetch>(
      async () => new Response(null, { status: 202 }),
    );
    const client = new NotifieClient(
      'sdk_test_key',
      'https://notifie.example/',
      'browser-123',
      request,
    );

    await client.track('notification_requested');

    expect(request).toHaveBeenCalledWith(
      'https://notifie.example/api/v1/events',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({ Authorization: 'Bearer sdk_test_key' }),
      }),
    );
    const init = request.mock.calls[0]?.[1];
    expect(JSON.parse(String(init?.body))).toEqual({
      events: [{
        anonymousId: 'browser-123',
        event: 'notification_requested',
        properties: {},
      }],
    });
  });
});