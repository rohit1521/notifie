import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  LOCAL_NOTIFICATION_ID_NAMESPACE,
  fromPlatformNotificationId,
  localNotificationSchema,
  nextLocalOccurrence,
  toPlatformNotificationId,
  type LocalSchedule,
} from '../src/local-notifications.ts';

function notification(overrides: Record<string, unknown> = {}) {
  return {
    id: 'daily-reminder',
    title: 'Time to practise',
    body: 'Your streak is waiting.',
    schedule: { type: 'daily', hour: 9, minute: 0 },
    ...overrides,
  };
}

describe('local notification content', () => {
  it('accepts a minimal daily reminder', () => {
    expect(localNotificationSchema.safeParse(notification()).success).toBe(true);
  });

  it('rejects an identifier claiming the reserved namespace', () => {
    const result = localNotificationSchema.safeParse(
      notification({ id: `${LOCAL_NOTIFICATION_ID_NAMESPACE}spoofed` }),
    );
    expect(result.success).toBe(false);
  });

  it('rejects identifiers that cannot survive the Android integer mapping', () => {
    for (const id of ['has space', 'has/slash', 'emoji-🎉', '']) {
      expect(localNotificationSchema.safeParse(notification({ id })).success).toBe(false);
    }
  });

  it('rejects custom data using the reserved remote prefix', () => {
    const result = localNotificationSchema.safeParse(
      notification({ customData: { gk_invocation_id: 'stolen' } }),
    );
    expect(result.success).toBe(false);
  });

  it('measures the custom data budget in UTF-8 bytes, not code units', () => {
    // 1200 three-byte characters is under any length-based limit but over 4 KB.
    const wide = { note: '한'.repeat(1200) };
    expect(localNotificationSchema.safeParse(notification({ customData: wide })).success)
      .toBe(false);
  });

  it('keeps platform options out of the portable surface', () => {
    const result = localNotificationSchema.safeParse(
      notification({ platform: { android: { exact: true }, ios: { badge: 3 } } }),
    );
    expect(result.success).toBe(true);
  });

  it('rejects unknown platform options rather than ignoring them', () => {
    const result = localNotificationSchema.safeParse(
      notification({ platform: { android: { exactly: true } } }),
    );
    expect(result.success).toBe(false);
  });

  it('rejects unknown top-level fields', () => {
    expect(localNotificationSchema.safeParse(notification({ sound: 'ping' })).success)
      .toBe(false);
  });
});

describe('nextLocalOccurrence', () => {
  // Pinned to a timezone that observes daylight saving. Without this the
  // schedule tests are only as meaningful as the developer's machine settings:
  // in a non-DST zone such as IST the transition case passes trivially and
  // would not catch a drifting implementation.
  const originalTimezone = process.env.TZ;
  beforeAll(() => {
    process.env.TZ = 'America/New_York';
  });
  afterAll(() => {
    process.env.TZ = originalTimezone;
  });

  // Built inside each test rather than at module scope: describe bodies run
  // before beforeAll, so a date created there would be parsed in the machine's
  // timezone and silently defeat the pinning above.
  const noon = () => new Date('2026-03-10T12:00:00');

  it('returns null for an absolute time already past', () => {
    const schedule: LocalSchedule = { type: 'at', timestamp: '2020-01-01T00:00:00Z' };
    expect(nextLocalOccurrence(schedule, noon())).toBeNull();
  });

  it('returns the instant for a future absolute time', () => {
    const schedule: LocalSchedule = { type: 'at', timestamp: '2026-03-10T18:30:00Z' };
    expect(nextLocalOccurrence(schedule, noon())?.toISOString()).toBe('2026-03-10T18:30:00.000Z');
  });

  it('adds the interval for a relative schedule', () => {
    const next = nextLocalOccurrence({ type: 'in', seconds: 90 }, noon());
    expect(next?.getTime()).toBe(noon().getTime() + 90_000);
  });

  it('moves a daily time that already passed today to tomorrow', () => {
    const next = nextLocalOccurrence({ type: 'daily', hour: 9, minute: 0 }, noon());
    expect(next?.getDate()).toBe(11);
    expect(next?.getHours()).toBe(9);
  });

  it('keeps a daily time still ahead today on today', () => {
    const next = nextLocalOccurrence({ type: 'daily', hour: 18, minute: 30 }, noon());
    expect(next?.getDate()).toBe(10);
    expect(next?.getHours()).toBe(18);
  });

  it('holds the wall-clock hour across a daylight-saving transition', () => {
    // US DST begins 8 March 2026. A fixed 24h interval would drift by an hour;
    // a wall-clock schedule must not.
    const beforeTransition = new Date('2026-03-07T20:00:00');
    const next = nextLocalOccurrence({ type: 'daily', hour: 9, minute: 0 }, beforeTransition);
    expect(next?.getHours()).toBe(9);
    expect(next?.getMinutes()).toBe(0);
  });

  it('schedules a weekly slot later this week without skipping a week', () => {
    // 10 March 2026 is a Tuesday; Thursday is two days later.
    const next = nextLocalOccurrence({ type: 'weekly', weekday: 4, hour: 9, minute: 0 }, noon());
    expect(next?.getDate()).toBe(12);
  });

  it('rolls a weekly slot that already passed today to next week', () => {
    const next = nextLocalOccurrence({ type: 'weekly', weekday: 2, hour: 9, minute: 0 }, noon());
    expect(next?.getDate()).toBe(17);
  });

  it('keeps a weekly slot still ahead today on today', () => {
    const next = nextLocalOccurrence({ type: 'weekly', weekday: 2, hour: 18, minute: 0 }, noon());
    expect(next?.getDate()).toBe(10);
  });

  it('treats Sunday as ISO weekday 7', () => {
    const next = nextLocalOccurrence({ type: 'weekly', weekday: 7, hour: 9, minute: 0 }, noon());
    expect(next?.getDay()).toBe(0);
    expect(next?.getDate()).toBe(15);
  });
});

describe('identifier namespacing', () => {
  it('round-trips a caller identifier', () => {
    const platformId = toPlatformNotificationId('daily-reminder');
    expect(platformId).toBe('notifie.local.daily-reminder');
    expect(fromPlatformNotificationId(platformId)).toBe('daily-reminder');
  });

  it('does not claim identifiers it did not create', () => {
    expect(fromPlatformNotificationId('some-cloud-invocation')).toBeNull();
  });
});
