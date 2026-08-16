import { describe, expect, it, vi } from 'vitest';
import {
  Notifie,
  type NotifieFetch,
} from '../src/index.ts';

function jsonResponse(body: unknown, status = 200, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

describe('Notifie server SDK', () => {
  it('sends direct notifications with a stable generated idempotency key', async () => {
    const request = vi.fn<NotifieFetch>(async () => jsonResponse({
      accepted: true,
      recipientCount: 1,
      jobIds: ['job-1'],
    }, 202));
    const growth = new Notifie({
      sendKey: 'send-key',
      baseUrl: 'https://notifie.dev/',
      fetch: request,
    });

    const result = await growth.notify({
      to: 'user-123',
      type: 'social',
      notification: {
        title: '{{actor_name}} liked your post',
        body: 'Open {{post_id}}',
      },
      parameters: { actor_name: 'Maya', post_id: 'post-7' },
    });

    expect(result.jobIds).toEqual(['job-1']);
    expect(request.mock.calls[0]?.[0]).toBe('https://notifie.dev/api/v1/send');
    const payload = JSON.parse(String(request.mock.calls[0]?.[1]?.body));
    expect(payload).toMatchObject({
      to: 'user-123',
      type: 'social',
      parameters: { actor_name: 'Maya', post_id: 'post-7' },
    });
    expect(payload.idempotencyKey).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('retries transient event failures with the same generated message id', async () => {
    const request = vi.fn<NotifieFetch>()
      .mockResolvedValueOnce(jsonResponse({ error: 'busy' }, 503, { 'Retry-After': '0' }))
      .mockResolvedValueOnce(jsonResponse({ received: 1, inserted: 1, duplicates: 0 }));
    const growth = new Notifie({ apiKey: 'ingest-key', fetch: request });

    await growth.track('order_completed', {
      userId: 'user-123',
      properties: { order_id: '42' },
    });

    expect(request).toHaveBeenCalledTimes(2);
    const first = JSON.parse(String(request.mock.calls[0]?.[1]?.body));
    const second = JSON.parse(String(request.mock.calls[1]?.[1]?.body));
    expect(first.events[0].messageId).toMatch(/^[0-9a-f-]{36}$/);
    expect(second.events[0].messageId).toBe(first.events[0].messageId);
  });

  it('triggers recipient Flows with stable retry data and a send key', async () => {
    const request = vi.fn<NotifieFetch>()
      .mockResolvedValueOnce(jsonResponse({ error: 'busy' }, 503, { 'Retry-After': '0' }))
      .mockResolvedValueOnce(jsonResponse({
        accepted: true,
        recipientCount: 1,
        inserted: 1,
        duplicates: 0,
      }, 202));
    const growth = new Notifie({ sendKey: 'send-key', fetch: request });

    const result = await growth.trigger('post_liked', {
      to: 'post-owner',
      data: { actor_name: 'Maya', post_id: 'post-7' },
    });

    expect(result).toMatchObject({ accepted: true, inserted: 1 });
    expect(request).toHaveBeenCalledTimes(2);
    expect(request.mock.calls[0]?.[0]).toBe('https://notifie.dev/api/v1/trigger');
    const first = JSON.parse(String(request.mock.calls[0]?.[1]?.body));
    const second = JSON.parse(String(request.mock.calls[1]?.[1]?.body));
    expect(first).toMatchObject({
      event: 'post_liked',
      to: 'post-owner',
      data: { actor_name: 'Maya', post_id: 'post-7' },
    });
    expect(first.idempotencyKey).toMatch(/^[0-9a-f-]{36}$/);
    expect(second.idempotencyKey).toBe(first.idempotencyKey);
  });

  it('uses separate ingest and send keys when both are configured', async () => {
    const request = vi.fn<NotifieFetch>()
      .mockResolvedValueOnce(jsonResponse({ userId: 'internal-user-id' }))
      .mockResolvedValueOnce(jsonResponse({
        accepted: true,
        recipientCount: 1,
        inserted: 1,
        duplicates: 0,
      }, 202));
    const growth = new Notifie({
      ingestKey: 'ingest-key',
      sendKey: 'send-key',
      fetch: request,
    });

    await growth.identify('user-123', { plan: 'pro' });
    await growth.trigger('account_ready', {
      to: 'user-123',
      data: { plan: 'pro' },
    });

    const firstHeaders = new Headers(request.mock.calls[0]?.[1]?.headers);
    const secondHeaders = new Headers(request.mock.calls[1]?.[1]?.headers);
    expect(firstHeaders.get('Authorization')).toContain('ingest-key');
    expect(secondHeaders.get('Authorization')).toContain('send-key');
  });

  it('does not retry permanent API errors', async () => {
    const request = vi.fn<NotifieFetch>(async () => jsonResponse({
      error: 'Invalid request',
    }, 404));
    const growth = new Notifie({ sendKey: 'send-key', fetch: request });

    await expect(growth.trigger('account_ready', { to: 'missing-user' })).rejects.toMatchObject({
      name: 'NotifieError',
      status: 404,
      message: 'Invalid request',
    });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('retries when reading a response body fails', async () => {
    const failedBody = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new Error('stream reset'));
      },
    });
    const request = vi.fn<NotifieFetch>()
      .mockResolvedValueOnce(new Response(failedBody, { status: 503 }))
      .mockResolvedValueOnce(jsonResponse({
        accepted: true,
        recipientCount: 1,
        inserted: 1,
        duplicates: 0,
      }, 202));
    const growth = new Notifie({ sendKey: 'send-key', fetch: request });

    await expect(growth.trigger('account_ready', { to: 'user-123' })).resolves.toMatchObject({
      accepted: true,
    });
    expect(request).toHaveBeenCalledTimes(2);
  });
});
