import { z } from 'zod';

export const MAX_EVENT_NAME_LENGTH = 64;

/** Event names are flat identifiers, e.g. `purchase_completed`. */
export const eventNameSchema = z
  .string()
  .min(1, 'event name is required')
  .max(MAX_EVENT_NAME_LENGTH, `event name must be at most ${MAX_EVENT_NAME_LENGTH} characters`)
  .regex(
    /^[A-Za-z0-9][A-Za-z0-9 _.:-]*$/,
    'event name must start alphanumeric and contain only letters, numbers, spaces, _ . : -',
  );
