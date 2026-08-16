import { z } from 'zod';
import { utf8ByteLength } from './text.ts';

/**
 * The local notification contract.
 *
 * Local notifications are scheduled and presented entirely by the operating
 * system on one device. Nothing here reaches a server, so this contract exists
 * to keep the four Device SDKs describing the same behavior rather than to
 * serialize a request.
 *
 * The portable surface is deliberately small. Anything expressible on only one
 * platform belongs in `platform`, so that reading the portable fields tells you
 * what will actually happen everywhere.
 */

/**
 * Reserved identifier namespace.
 *
 * A local notification and a Cloud push both end up as an OS notification with
 * an identifier. If those identifiers shared a space, cancelling a local
 * reminder could remove a delivered Cloud notification, and an open could be
 * attributed to the wrong one. SDKs therefore prefix caller IDs with this
 * namespace before handing them to the platform, and reject caller IDs that
 * already start with it so the namespace cannot be forged.
 */
export const LOCAL_NOTIFICATION_ID_NAMESPACE = 'notifie.local.';

export const MAX_LOCAL_NOTIFICATION_ID_LENGTH = 64;
export const MAX_LOCAL_CUSTOM_DATA_KEYS = 20;
export const MAX_LOCAL_CUSTOM_DATA_BYTES = 4096;

/**
 * Identifier charset.
 *
 * Restricted because these strings cross three type systems: an iOS request
 * identifier (string), an Android notification ID (int) and a `PendingIntent`
 * request code (int). The Android integers are derived by hashing this string,
 * so it must be stable, printable and free of the whitespace and separators
 * that intent extras and log lines handle inconsistently.
 */
const localNotificationIdSchema = z
  .string()
  .min(1)
  .max(MAX_LOCAL_NOTIFICATION_ID_LENGTH)
  .regex(
    /^[A-Za-z0-9._:-]+$/,
    'Use only letters, digits, dot, underscore, colon or hyphen.',
  )
  .refine(
    (id) => !id.startsWith(LOCAL_NOTIFICATION_ID_NAMESPACE),
    `Identifiers must not start with the reserved "${LOCAL_NOTIFICATION_ID_NAMESPACE}" namespace.`,
  );

const localCustomDataSchema = z
  .record(z.string().min(1).max(128), z.string().max(1024))
  .refine(
    (data) => Object.keys(data).length <= MAX_LOCAL_CUSTOM_DATA_KEYS,
    `At most ${MAX_LOCAL_CUSTOM_DATA_KEYS} custom data fields are allowed.`,
  )
  .refine(
    (data) => utf8ByteLength(JSON.stringify(data)) <= MAX_LOCAL_CUSTOM_DATA_BYTES,
    'Custom data must be at most 4 KB.',
  )
  .refine(
    (data) => Object.keys(data).every((key) => !key.startsWith('gk_')),
    'Custom data must not use the reserved gk_ prefix.',
  );

/** Fires once at an absolute instant. */
const atScheduleSchema = z.object({
  type: z.literal('at'),
  /**
   * An instant, not a wall-clock time. If the device changes timezone before
   * it fires, this still fires at the same moment worldwide.
   */
  timestamp: z.string().datetime({ offset: true }).or(z.string().datetime()),
});

/** Fires once after a delay measured from scheduling. */
const inScheduleSchema = z.object({
  type: z.literal('in'),
  seconds: z
    .number()
    .int()
    .min(1)
    // A year. Longer intervals are better expressed as an absolute instant,
    // and both platforms become unreliable across that span anyway.
    .max(365 * 24 * 60 * 60),
});

const hourSchema = z.number().int().min(0).max(23);
const minuteSchema = z.number().int().min(0).max(59);

/**
 * Fires every day at a wall-clock time.
 *
 * Wall clock rather than a fixed interval: a 9am reminder must stay at 9am
 * across a daylight-saving transition. Repeating every 86400 seconds would
 * silently drift to 8am or 10am and stay there.
 */
const dailyScheduleSchema = z.object({
  type: z.literal('daily'),
  hour: hourSchema,
  minute: minuteSchema,
});

/** Fires every week at a wall-clock time. Monday is 1, Sunday is 7 (ISO-8601). */
const weeklyScheduleSchema = z.object({
  type: z.literal('weekly'),
  weekday: z.number().int().min(1).max(7),
  hour: hourSchema,
  minute: minuteSchema,
});

/**
 * Monthly recurrence is deliberately absent.
 *
 * "The 31st of every month" has no correct answer in February, and every
 * available behavior — skip, clamp, roll forward — silently surprises somebody.
 * An explicit sequence of `at` schedules expresses the intent without guessing.
 */
export const localScheduleSchema = z.discriminatedUnion('type', [
  atScheduleSchema,
  inScheduleSchema,
  dailyScheduleSchema,
  weeklyScheduleSchema,
]);

/**
 * Platform-specific options.
 *
 * Isolated so the portable fields stay portable. A value here affects one
 * platform and is ignored elsewhere, which is a property callers can rely on
 * rather than discover.
 */
const platformOptionsSchema = z
  .object({
    ios: z
      .object({
        /** `UNNotificationContent.threadIdentifier`, used for grouping. */
        threadId: z.string().min(1).max(64).optional(),
        /** A `UNNotificationCategory` registered by the host application. */
        categoryId: z.string().min(1).max(64).optional(),
        /** Application badge to apply when presented. */
        badge: z.number().int().min(0).max(99_999).optional(),
        /** `false` uses no sound; a string names a bundled sound file. */
        sound: z.union([z.boolean(), z.string().min(1).max(64)]).optional(),
        interruptionLevel: z
          .enum(['passive', 'active', 'timeSensitive', 'critical'])
          .optional(),
      })
      .strict()
      .optional(),
    android: z
      .object({
        /** Existing notification channel. Falls back to the SDK default. */
        channelId: z.string().min(1).max(64).optional(),
        /**
         * Requests exact delivery.
         *
         * Off by default because exact alarms require a user-visible
         * permission on Android 12+ and are a scarce system resource. The
         * scheduling result reports the precision actually granted, so a
         * denied request degrades to inexact rather than failing.
         */
        exact: z.boolean().optional(),
        /** Survives Doze. Use only for user-critical alarms such as alarms clocks. */
        allowWhileIdle: z.boolean().optional(),
        smallIconName: z.string().min(1).max(64).optional(),
        /** Grouping key, equivalent in spirit to iOS `threadId`. */
        groupKey: z.string().min(1).max(64).optional(),
      })
      .strict()
      .optional(),
  })
  .strict();

export const localNotificationSchema = z
  .object({
    /**
     * Stable, caller-owned identity. Scheduling the same ID replaces the
     * pending notification rather than adding a second one, which is what
     * makes scheduling safe to retry.
     */
    id: localNotificationIdSchema,
    title: z.string().min(1).max(100),
    body: z.string().min(1).max(250),
    schedule: localScheduleSchema,
    /** Delivered to the open handler; never opened by the SDK itself. */
    deepLink: z.string().url().optional(),
    /**
     * String-only, matching the remote contract. Platform payloads are string
     * dictionaries, so allowing richer values here would mean each SDK
     * inventing its own encoding and disagreeing at the boundary.
     */
    customData: localCustomDataSchema.optional(),
    platform: platformOptionsSchema.optional(),
  })
  .strict();

/** Why a local notification could not be scheduled. */
export const localScheduleErrorSchema = z.enum([
  /** Content or schedule failed validation. */
  'invalid_request',
  /** The user has not granted notification permission. */
  'permission_denied',
  /** The requested time has already passed. */
  'schedule_in_past',
  /**
   * The platform pending-notification limit is reached.
   *
   * iOS keeps only the 64 soonest pending requests and discards the rest in
   * silence. Reporting capacity explicitly is the difference between a
   * developer learning this now and learning it from a user.
   */
  'capacity_exceeded',
  /** The platform rejected the request for a reason the SDK cannot classify. */
  'platform_error',
]);

/**
 * Delivery precision actually granted.
 *
 * Returned rather than assumed: Android downgrades exact alarms when the
 * permission is absent, and a scheduler that claimed exactness it did not
 * receive would be lying at the moment accuracy matters.
 */
export const localSchedulePrecisionSchema = z.enum(['exact', 'inexact']);

export type LocalSchedule = z.infer<typeof localScheduleSchema>;
export type LocalNotification = z.infer<typeof localNotificationSchema>;
export type LocalNotificationInput = z.input<typeof localNotificationSchema>;
export type LocalScheduleError = z.infer<typeof localScheduleErrorSchema>;
export type LocalSchedulePrecision = z.infer<typeof localSchedulePrecisionSchema>;
export type LocalPlatformOptions = z.infer<typeof platformOptionsSchema>;

/** Namespaces a caller identifier for the platform notification store. */
export function toPlatformNotificationId(id: string): string {
  return `${LOCAL_NOTIFICATION_ID_NAMESPACE}${id}`;
}

/** Recovers a caller identifier, or null when the ID is not a Notifie local one. */
export function fromPlatformNotificationId(platformId: string): string | null {
  return platformId.startsWith(LOCAL_NOTIFICATION_ID_NAMESPACE)
    ? platformId.slice(LOCAL_NOTIFICATION_ID_NAMESPACE.length)
    : null;
}

/**
 * Resolves the next firing instant for a schedule.
 *
 * Shared so the SDKs and their tests agree on the boundary cases rather than
 * each re-deriving them: a daily time that has already passed today belongs to
 * tomorrow, and a weekly slot occurring later today must not skip a week.
 *
 * Returns null for a one-shot schedule already in the past, which callers
 * report as `schedule_in_past` rather than scheduling something that can never
 * fire.
 */
export function nextLocalOccurrence(schedule: LocalSchedule, from: Date): Date | null {
  switch (schedule.type) {
    case 'at': {
      const at = new Date(schedule.timestamp);
      return at.getTime() > from.getTime() ? at : null;
    }
    case 'in': {
      return new Date(from.getTime() + schedule.seconds * 1000);
    }
    case 'daily': {
      const next = withTime(from, schedule.hour, schedule.minute);
      if (next.getTime() <= from.getTime()) next.setDate(next.getDate() + 1);
      return next;
    }
    case 'weekly': {
      const next = withTime(from, schedule.hour, schedule.minute);
      // getDay() is 0-6 with Sunday first; the contract is ISO 1-7 with Monday
      // first, so Sunday maps to 7 rather than 0.
      const currentWeekday = next.getDay() === 0 ? 7 : next.getDay();
      let delta = schedule.weekday - currentWeekday;
      if (delta < 0) delta += 7;
      if (delta === 0 && next.getTime() <= from.getTime()) delta = 7;
      next.setDate(next.getDate() + delta);
      return next;
    }
  }
}

/**
 * Builds a local wall-clock time on the same calendar day.
 *
 * Mutating a copy rather than constructing from components keeps this in the
 * host's timezone, which is the whole point of a calendar schedule.
 */
function withTime(from: Date, hour: number, minute: number): Date {
  const next = new Date(from.getTime());
  next.setHours(hour, minute, 0, 0);
  return next;
}
