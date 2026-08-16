import { describe, expect, it } from 'vitest';
import { notifyCommandSchema } from '../src/notify.ts';

describe('notifyCommandSchema', () => {
  it('accepts an immediate personalized alert', () => {
    expect(notifyCommandSchema.safeParse({
      to: 'user-123',
      type: 'transactional',
      notification: {
        title: 'Order {{order_id}} delivered',
        body: 'Your item has arrived.',
      },
      parameters: { order_id: 'A-42' },
      idempotencyKey: 'order-A-42-delivered',
    }).success).toBe(true);
  });

  it('accepts bulk, delayed, and background notifications', () => {
    expect(notifyCommandSchema.safeParse({
      to: ['user-1', 'user-2'],
      type: 'background',
      delaySeconds: 120,
      notification: {
        mode: 'background',
        customData: { sync: 'inventory' },
        collapseId: 'inventory-sync',
      },
    }).success).toBe(true);
  });

  it('rejects conflicting schedules and empty background data', () => {
    expect(notifyCommandSchema.safeParse({
      to: 'user-1',
      deliverAt: '2027-01-01T00:00:00.000Z',
      delaySeconds: 60,
      notification: { title: 'Hi', body: 'Body' },
    }).success).toBe(false);
    expect(notifyCommandSchema.safeParse({
      to: 'user-1',
      notification: { mode: 'background', customData: {} },
    }).success).toBe(false);
    expect(notifyCommandSchema.safeParse({
      to: 'user-1',
      notification: {
        mode: 'background',
        customData: { 'google.internal': 'forbidden' },
      },
    }).success).toBe(false);
    expect(notifyCommandSchema.safeParse({
      to: 'user-1',
      notification: {
        title: 'Hi',
        body: 'Body',
        customData: {
          first: 'x'.repeat(1024),
          second: 'x'.repeat(1024),
        },
      },
    }).success).toBe(false);
  });
});