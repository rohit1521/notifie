import { describe, expect, it } from 'vitest';
import {
  MAX_EVENTS_PER_BATCH,
  parseApiKey,
  identifySchema,
  trackBatchSchema,
  trackEventSchema,
} from '../src/index.js';

describe('trackEventSchema', () => {
  it('accepts a well formed event', () => {
    const result = trackEventSchema.safeParse({
      userId: '123',
      event: 'purchase_completed',
      timestamp: '2026-08-07T10:00:00.000Z',
      properties: { amount: 9.99, plan: 'monthly' },
      messageId: '3f1b6a1e-9b3e-4f2a-8c1d-2b4e6f8a0c11',
    });

    expect(result.success).toBe(true);
  });

  it('accepts an anonymous event with no userId', () => {
    const result = trackEventSchema.safeParse({
      anonymousId: 'device-abc',
      event: 'app_open',
    });

    expect(result.success).toBe(true);
  });

  it('rejects an event with neither userId nor anonymousId', () => {
    const result = trackEventSchema.safeParse({ event: 'app_open' });

    expect(result.success).toBe(false);
  });

  it('rejects nested property objects so jsonb stays queryable', () => {
    const result = trackEventSchema.safeParse({
      userId: '123',
      event: 'purchase_completed',
      properties: { nested: { deep: true } },
    });

    expect(result.success).toBe(false);
  });

  it('rejects event names that do not start alphanumeric', () => {
    const result = trackEventSchema.safeParse({ userId: '1', event: '_leading' });

    expect(result.success).toBe(false);
  });

  it('rejects a non-uuid messageId', () => {
    const result = trackEventSchema.safeParse({
      userId: '1',
      event: 'app_open',
      messageId: 'not-a-uuid',
    });

    expect(result.success).toBe(false);
  });
});

describe('trackBatchSchema', () => {
  const event = { userId: '1', event: 'app_open' };

  it('rejects an empty batch', () => {
    expect(trackBatchSchema.safeParse({ events: [] }).success).toBe(false);
  });

  it(`accepts exactly ${MAX_EVENTS_PER_BATCH} events`, () => {
    const events = Array.from({ length: MAX_EVENTS_PER_BATCH }, () => event);

    expect(trackBatchSchema.safeParse({ events }).success).toBe(true);
  });

  it('rejects a batch over the limit', () => {
    const events = Array.from({ length: MAX_EVENTS_PER_BATCH + 1 }, () => event);

    expect(trackBatchSchema.safeParse({ events }).success).toBe(false);
  });
});

describe('identifySchema', () => {
  it('requires a userId', () => {
    expect(identifySchema.safeParse({ anonymousId: 'device-abc' }).success).toBe(false);
    expect(identifySchema.safeParse({ userId: 'user-1' }).success).toBe(true);
  });
});

describe('parseApiKey', () => {
  const secret = 'a'.repeat(32);

  it('parses a valid live key', () => {
    expect(parseApiKey(`gk_live_abcdef123456_${secret}`)).toEqual({
      environment: 'live',
      lookup: 'abcdef123456',
      secret,
    });
  });

  it('uses the Notifie prefix for new keys and accepts legacy keys', () => {
    expect(parseApiKey(`ntf_live_abcdef123456_${secret}`)).toEqual({
      environment: 'live',
      lookup: 'abcdef123456',
      secret,
    });
    expect(parseApiKey(`gk_live_abcdef123456_${secret}`)).not.toBeNull();
  });

  // Regression: base64url secrets can contain `_`, which previously split the
  // key into five parts and rejected a perfectly valid credential.
  it('parses a key whose secret contains underscores', () => {
    const awkward = `ab_cd${'x'.repeat(26)}_ef`;
    expect(parseApiKey(`gk_live_abcdef123456_${awkward}`)).toEqual({
      environment: 'live',
      lookup: 'abcdef123456',
      secret: awkward,
    });
  });

  it('rejects an unknown prefix', () => {
    expect(parseApiKey(`xx_live_abcdef123456_${secret}`)).toBeNull();
  });

  it('rejects an unknown environment', () => {
    expect(parseApiKey(`gk_prod_abcdef123456_${secret}`)).toBeNull();
  });

  it('rejects a wrong-length lookup segment', () => {
    expect(parseApiKey(`gk_live_short_${secret}`)).toBeNull();
  });

  it('rejects a short secret', () => {
    expect(parseApiKey('gk_live_abcdef123456_tooshort')).toBeNull();
  });

  it('rejects malformed input', () => {
    expect(parseApiKey('garbage')).toBeNull();
    expect(parseApiKey('')).toBeNull();
    expect(parseApiKey('gk_live_abcdef123456')).toBeNull();
  });
});
