export type ProviderClassification =
  | 'ok'
  | 'dead_token'
  | 'permanent'
  | 'retryable';

export interface ProviderSendResult {
  provider: 'apns' | 'fcm';
  providerAccepted: boolean;
  status: number;
  classification: ProviderClassification;
  reason?: string;
  messageId?: string;
  retryAfterSeconds?: number;
}

export interface ApnsProviderResult {
  ok: boolean;
  status: number;
  reason?: string;
  messageId?: string;
  retryAfterSeconds?: number;
}

export interface FcmProviderResult {
  ok: boolean;
  status: number;
  errorCode?: string;
  messageId?: string;
  retryAfterSeconds?: number;
}
