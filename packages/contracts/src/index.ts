import { z } from 'zod';
import { eventNameSchema } from './events.ts';

export { eventNameSchema, MAX_EVENT_NAME_LENGTH } from './events.ts';

export const MAX_EVENTS_PER_BATCH = 100;
export const MAX_USER_ID_LENGTH = 256;
export const MAX_PROPERTY_KEYS = 64;
export const MAX_STRING_PROPERTY_LENGTH = 1024;

export const propertyValueSchema = z.union([
  z.string().max(MAX_STRING_PROPERTY_LENGTH),
  z.number().finite(),
  z.boolean(),
  z.null(),
]);

export const propertiesSchema = z
  .record(z.string().min(1).max(128), propertyValueSchema)
  .refine((value) => Object.keys(value).length <= MAX_PROPERTY_KEYS, {
    message: `at most ${MAX_PROPERTY_KEYS} properties are allowed`,
  });

const userIdSchema = z.string().min(1).max(MAX_USER_ID_LENGTH);
const timestampSchema = z
  .string()
  .datetime({ offset: true })
  .or(z.string().datetime())
  .describe('ISO-8601 timestamp');

const identitySchema = z.object({
  userId: userIdSchema.optional(),
  anonymousId: userIdSchema.optional(),
});

export const trackEventSchema = identitySchema
  .extend({
    event: eventNameSchema,
    timestamp: timestampSchema.optional(),
    properties: propertiesSchema.optional(),
    messageId: z.string().uuid().optional(),
  })
  .refine((value) => Boolean(value.userId ?? value.anonymousId), {
    message: 'either userId or anonymousId must be provided',
    path: ['userId'],
  });

export const trackBatchSchema = z.object({
  events: z.array(trackEventSchema).min(1).max(MAX_EVENTS_PER_BATCH),
  sentAt: timestampSchema.optional(),
});

export const identifySchema = identitySchema
  .extend({
    userId: userIdSchema,
    properties: propertiesSchema.optional(),
    timestamp: timestampSchema.optional(),
  })
  .refine((value) => Boolean(value.userId), {
    message: 'userId is required',
    path: ['userId'],
  });

export const triggerCommandSchema = z.object({
  to: z.union([
    userIdSchema,
    z.array(userIdSchema).min(1).max(MAX_EVENTS_PER_BATCH),
  ]),
  data: propertiesSchema.default({}),
  idempotencyKey: z.string().trim().min(1).max(128).optional(),
  timestamp: timestampSchema.optional(),
}).strict();

export const triggerRequestSchema = triggerCommandSchema.extend({
  event: eventNameSchema,
});

export const API_KEY_PREFIX = 'ntf';
export const LEGACY_API_KEY_PREFIX = 'gk';
export const API_KEY_LOOKUP_LENGTH = 12;
export const API_KEY_PREFIXES = [API_KEY_PREFIX, LEGACY_API_KEY_PREFIX] as const;

export interface ParsedApiKey {
  environment: string;
  lookup: string;
  secret: string;
}

export function parseApiKey(raw: string): ParsedApiKey | null {
  const parts = raw.trim().split('_');
  if (parts.length < 4) return null;

  const [prefix, environment, lookup, ...secretParts] = parts as [
    string,
    string,
    string,
    ...string[],
  ];
  const secret = secretParts.join('_');

  if (!(API_KEY_PREFIXES as readonly string[]).includes(prefix)) return null;
  if (environment !== 'live' && environment !== 'test') return null;
  if (lookup.length !== API_KEY_LOOKUP_LENGTH) return null;
  if (secret.length < 24) return null;

  return { environment, lookup, secret };
}

export const APP_PLATFORMS = ['ios', 'android', 'web', 'flutter', 'react-native'] as const;
export type AppPlatform = (typeof APP_PLATFORMS)[number];

export const pushTokenSchema = z
  .object({
    userId: userIdSchema.optional(),
    anonymousId: userIdSchema.optional(),
    token: z.string().min(1).max(512),
    platform: z.enum(['ios', 'android']),
    provider: z.enum(['apns', 'fcm']),
  })
  .refine((value) => Boolean(value.userId ?? value.anonymousId), {
    message: 'either userId or anonymousId must be provided',
    path: ['userId'],
  });

export const pushTokenRevocationSchema = z.object({
  token: z.string().min(1).max(512),
});

export type PropertyValue = z.infer<typeof propertyValueSchema>;
export type EventProperties = z.infer<typeof propertiesSchema>;
export type TrackEvent = z.infer<typeof trackEventSchema>;
export type TrackBatch = z.infer<typeof trackBatchSchema>;
export type IdentifyPayload = z.infer<typeof identifySchema>;
export type TriggerCommandInput = z.input<typeof triggerCommandSchema>;
export type TriggerCommand = z.infer<typeof triggerCommandSchema>;
export type TriggerRequest = z.infer<typeof triggerRequestSchema>;
export type PushTokenPayload = z.infer<typeof pushTokenSchema>;
export type PushTokenRevocationPayload = z.infer<typeof pushTokenRevocationSchema>;

export * from './notify.ts';
export * from './local-notifications.ts';
export * from './apns-verification.ts';
export * from './provider-results.ts';
