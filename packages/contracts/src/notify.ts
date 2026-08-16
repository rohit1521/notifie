import { z } from 'zod';
import { utf8ByteLength } from './text.ts';

const reservedDataKeys = new Set([
  'aps',
  'google',
  'gcm',
  'from',
  'message_type',
  'collapse_key',
  'gk_invocation_id',
  'gk_deep_link',
  'gk_image_url',
]);

function isReservedDataKey(key: string): boolean {
  return reservedDataKeys.has(key)
    || key.startsWith('google.')
    || key.startsWith('gcm.');
}

const parameterValueSchema = z.union([
  z.string().max(1024),
  z.number().finite(),
  z.boolean(),
  z.null(),
]);

const commandParametersSchema = z
  .record(z.string().min(1).max(128), parameterValueSchema)
  .refine((parameters) => Object.keys(parameters).length <= 64, {
    message: 'At most 64 parameters are allowed.',
  });

const backgroundPayloadSchema = z.object({
  mode: z.literal('background'),
  customData: z.record(z.string().min(1).max(128), z.string().max(1024)).refine(
    (data) => Object.keys(data).length > 0 && Object.keys(data).length <= 20,
    'Background notifications require 1-20 data fields.',
  ).refine(
    (data) => Object.keys(data).every((key) => !isReservedDataKey(key)),
    'Custom data uses a reserved Notifie or provider key.',
  ).refine(
    (data) => utf8ByteLength(JSON.stringify(data)) <= 2048,
    'Custom data must be at most 2 KB.',
  ),
  collapseId: z.string().min(1).max(64).optional(),
  ttlSeconds: z.number().int().min(0).max(28 * 24 * 60 * 60).optional(),
});

const alertPayloadSchema = z.object({
  mode: z.literal('alert').optional(),
  title: z.string().min(1).max(100),
  body: z.string().min(1).max(250),
  deepLink: z.string().url().optional(),
  imageUrl: z.string().url().optional(),
  sound: z.string().min(1).max(64).optional(),
  badge: z.number().int().min(0).max(99_999).optional(),
  collapseId: z.string().min(1).max(64).optional(),
  threadId: z.string().min(1).max(64).optional(),
  category: z.string().min(1).max(64).optional(),
  ttlSeconds: z.number().int().min(0).max(28 * 24 * 60 * 60).optional(),
  customData: z
    .record(z.string().min(1).max(128), z.string().max(1024))
    .refine((data) => Object.keys(data).length <= 20, 'At most 20 custom data fields are allowed.')
    .refine(
      (data) => utf8ByteLength(JSON.stringify(data)) <= 2048,
      'Custom data must be at most 2 KB.',
    )
    .refine(
      (data) => Object.keys(data).every((key) => !isReservedDataKey(key)),
      'Custom data uses a reserved Notifie or provider key.',
    )
    .optional(),
});

export const notifyPayloadSchema = z.union([
  alertPayloadSchema,
  backgroundPayloadSchema,
]);

export const notificationTypeSchema = z.enum([
  'transactional',
  'social',
  'state_change',
  'progress',
  'reminder',
  'lifecycle',
  'marketing',
  'security',
  'system',
  'background',
]);

export const notifyCommandSchema = z
  .object({
    to: z.union([
      z.string().min(1).max(256),
      z.array(z.string().min(1).max(256)).min(1).max(100),
    ]),
    notification: notifyPayloadSchema,
    parameters: commandParametersSchema.optional(),
    type: notificationTypeSchema.default('transactional'),
    deliverAt: z.string().datetime().optional(),
    delaySeconds: z.number().int().min(1).max(30 * 24 * 60 * 60).optional(),
    idempotencyKey: z.string().trim().min(1).max(128).optional(),
  })
  .strict()
  .refine((command) => !(command.deliverAt && command.delaySeconds), {
    message: 'Use either deliverAt or delaySeconds, not both.',
    path: ['deliverAt'],
  });

export type NotifyPayload = z.infer<typeof notifyPayloadSchema>;
export type NotifyCommandInput = z.input<typeof notifyCommandSchema>;
export type NotifyCommand = z.infer<typeof notifyCommandSchema>;
export type NotificationType = z.infer<typeof notificationTypeSchema>;