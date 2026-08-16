import { randomUUID } from 'node:crypto';
import {
  identifySchema,
  notifyCommandSchema,
  trackBatchSchema,
  triggerRequestSchema,
  type EventProperties,
  type NotifyCommandInput,
  type TriggerCommandInput,
} from '@notifie/contracts';

export type {
  EventProperties,
  NotificationType,
  NotifyCommand,
  NotifyCommandInput,
  NotifyPayload,
  TriggerCommand,
  TriggerCommandInput,
  TriggerRequest,
} from '@notifie/contracts';

export type NotifieFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export interface NotifieOptions {
  /** Convenience key for clients that only ingest or only send. */
  apiKey?: string;
  /** Ingest-scoped key used by track and identify. */
  ingestKey?: string;
  /** Server-only send-scoped key used by trigger and notify. */
  sendKey?: string;
  baseUrl?: string;
  fetch?: NotifieFetch;
  maxAttempts?: number;
}

type TrackIdentity =
  | { userId: string; anonymousId?: string }
  | { userId?: string; anonymousId: string };

export type TrackOptions = TrackIdentity & {
  properties?: EventProperties;
  timestamp?: string;
  messageId?: string;
};

export interface IdentifyOptions {
  anonymousId?: string;
  timestamp?: string;
}

export interface TrackResult {
  received: number;
  inserted: number;
  duplicates: number;
}

export interface IdentifyResult {
  userId: string;
}

export interface NotifyResult {
  accepted: true;
  recipientCount: number;
  jobIds: string[];
}

export interface TriggerResult {
  accepted: true;
  recipientCount: number;
  inserted: number;
  duplicates: number;
}

export class NotifieError extends Error {
  readonly status: number | null;
  readonly details: unknown;

  constructor(message: string, status: number | null, details?: unknown, cause?: unknown) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'NotifieError';
    this.status = status;
    this.details = details;
  }
}

export class Notifie {
  private readonly baseUrl: string;
  private readonly ingestKey: string | null;
  private readonly sendKey: string | null;
  private readonly request: NotifieFetch;
  private readonly maxAttempts: number;

  constructor(options: NotifieOptions) {
    const sharedKey = normalizeKey(options.apiKey);
    this.ingestKey = normalizeKey(options.ingestKey) ?? sharedKey;
    this.sendKey = normalizeKey(options.sendKey) ?? sharedKey;
    if (!this.ingestKey && !this.sendKey) {
      throw new Error('Configure apiKey, ingestKey, or sendKey.');
    }

    this.baseUrl = (options.baseUrl ?? 'https://notifie.dev').replace(/\/+$/, '');
    this.request = options.fetch ?? globalThis.fetch;
    if (typeof this.request !== 'function') {
      throw new Error('A fetch implementation is required.');
    }

    const maxAttempts = options.maxAttempts ?? 3;
    if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 5) {
      throw new Error('maxAttempts must be an integer from 1 to 5.');
    }
    this.maxAttempts = maxAttempts;
  }

  async track(event: string, options: TrackOptions): Promise<TrackResult> {
    const payload = trackBatchSchema.parse({
      events: [{
        event,
        userId: options.userId,
        anonymousId: options.anonymousId,
        properties: options.properties ?? {},
        timestamp: options.timestamp,
        messageId: options.messageId ?? randomUUID(),
      }],
    });
    return this.post('/api/v1/events', this.requireKey('ingest'), payload);
  }

  async identify(
    userId: string,
    properties: EventProperties = {},
    options: IdentifyOptions = {},
  ): Promise<IdentifyResult> {
    const payload = identifySchema.parse({
      userId,
      properties,
      anonymousId: options.anonymousId,
      timestamp: options.timestamp,
    });
    return this.post('/api/v1/identify', this.requireKey('ingest'), payload);
  }

  async notify(command: NotifyCommandInput): Promise<NotifyResult> {
    const payload = notifyCommandSchema.parse({
      ...command,
      idempotencyKey: command.idempotencyKey ?? randomUUID(),
    });
    return this.post('/api/v1/send', this.requireKey('send'), payload);
  }

  async trigger(event: string, command: TriggerCommandInput): Promise<TriggerResult> {
    const payload = triggerRequestSchema.parse({
      ...command,
      event,
      idempotencyKey: command.idempotencyKey ?? randomUUID(),
    });
    return this.post('/api/v1/trigger', this.requireKey('send'), payload);
  }

  private requireKey(scope: 'ingest' | 'send'): string {
    const key = scope === 'ingest' ? this.ingestKey : this.sendKey;
    if (!key) {
      throw new Error(`Configure ${scope}Key before calling this method.`);
    }
    return key;
  }

  private async post<T>(path: string, apiKey: string, payload: unknown): Promise<T> {
    const body = JSON.stringify(payload);
    let lastError: unknown;

    for (let attempt = 1; attempt <= this.maxAttempts; attempt += 1) {
      let response: Response;
      try {
        response = await this.request(`${this.baseUrl}${path}`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${apiKey}`,
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body,
        });
      } catch (error) {
        lastError = error;
        if (attempt === this.maxAttempts) break;
        await wait(retryDelayMs(null, attempt));
        continue;
      }

      let responseBody: unknown;
      try {
        responseBody = await readResponseBody(response);
      } catch (error) {
        lastError = error;
        if (attempt === this.maxAttempts) break;
        await wait(retryDelayMs(null, attempt));
        continue;
      }
      if (response.ok) return responseBody as T;

      if (attempt < this.maxAttempts && isRetryable(response.status)) {
        await wait(retryDelayMs(response.headers.get('Retry-After'), attempt));
        continue;
      }

      const message = isRecord(responseBody) && typeof responseBody['error'] === 'string'
        ? responseBody['error']
        : `Notifie request failed with status ${response.status}.`;
      throw this.createError(message, response.status, responseBody);
    }

    throw this.createError('Could not reach Notifie after retrying.', null, undefined, lastError);
  }

  protected createError(
    message: string,
    status: number | null,
    details?: unknown,
    cause?: unknown,
  ): NotifieError {
    return new NotifieError(message, status, details, cause);
  }
}


function normalizeKey(value: string | undefined): string | null {
  const key = value?.trim();
  return key ? key : null;
}

function isRetryable(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function retryDelayMs(retryAfter: string | null, attempt: number): number {
  if (retryAfter !== null) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) {
      return Math.min(seconds * 1000, 30_000);
    }
    const at = Date.parse(retryAfter);
    if (Number.isFinite(at)) return Math.min(Math.max(0, at - Date.now()), 30_000);
  }
  return Math.min(250 * 2 ** (attempt - 1), 4_000);
}

async function readResponseBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

async function wait(milliseconds: number): Promise<void> {
  if (milliseconds <= 0) return;
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}