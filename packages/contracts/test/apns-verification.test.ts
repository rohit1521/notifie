import { describe, expect, it } from 'vitest';
import {
  combineApnsProbes,
  explainApnsVerification,
  keyIdFromFilename,
  looksLikeP8,
} from '../src/apns-verification.js';

describe('explainApnsVerification', () => {
  /**
   * The probe sends to an invalid device token on purpose, so Apple objecting
   * to *the token* is the success signal — it can only have got that far by
   * accepting the key, key id, team id and topic first.
   */
  it('treats BadDeviceToken as success', () => {
    const result = explainApnsVerification(400, 'BadDeviceToken');
    expect(result.ok).toBe(true);
  });

  it('treats DeviceTokenNotForTopic as success', () => {
    expect(explainApnsVerification(400, 'DeviceTokenNotForTopic').ok).toBe(true);
  });

  /**
   * The specific trap this product needs to catch: Apple names App Store
   * Connect keys and APNs keys identically, so uploading the wrong one is easy
   * and the only symptom is that push silently never works.
   */
  it('explains InvalidProviderToken as the wrong kind of key', () => {
    const result = explainApnsVerification(403, 'InvalidProviderToken');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.problem).toBe('not-an-apns-key');
    expect(result.fix).toMatch(/App Store Connect/);
    expect(result.fix).toMatch(/Apple Push Notification service/);
  });

  it('distinguishes a wrong bundle id from a bad key', () => {
    const result = explainApnsVerification(403, 'TopicDisallowed');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.problem).toBe('wrong-bundle-id');
  });

  it('points at the clock for an expired token', () => {
    const result = explainApnsVerification(403, 'ExpiredProviderToken');
    if (result.ok) throw new Error('should not be ok');
    expect(result.problem).toBe('clock-skew');
  });

  it('owns MissingProviderToken as our bug, not the developer\'s', () => {
    const result = explainApnsVerification(403, 'MissingProviderToken');
    if (result.ok) throw new Error('should not be ok');
    expect(result.fix).toMatch(/Notifie bug/);
  });

  it('always offers a fix for a failure', () => {
    for (const reason of ['InvalidProviderToken', 'TopicDisallowed', 'Whatever', undefined]) {
      const result = explainApnsVerification(403, reason);
      if (result.ok) continue;
      expect(result.fix.length).toBeGreaterThan(0);
    }
  });

  it('does not claim success when Apple accepts an invalid token', () => {
    // Would mean the probe is not probing anything.
    expect(explainApnsVerification(200, undefined).ok).toBe(false);
  });
});

describe('keyIdFromFilename', () => {
  it('reads the key id Apple puts in the download name', () => {
    expect(keyIdFromFilename('AuthKey_6P2TX593NM.p8')).toBe('6P2TX593NM');
  });

  it('is case-insensitive and trims', () => {
    expect(keyIdFromFilename('  authkey_abc1234567.p8 ')).toBe('ABC1234567');
  });

  it('returns null rather than guessing at a renamed file', () => {
    expect(keyIdFromFilename('my-key.p8')).toBeNull();
    expect(keyIdFromFilename('AuthKey_SHORT.p8')).toBeNull();
    expect(keyIdFromFilename('AuthKey_6P2TX593NM.pem')).toBeNull();
  });
});

describe('looksLikeP8', () => {
  it('accepts a PKCS#8 key', () => {
    expect(looksLikeP8('-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----')).toBe(true);
  });

  it('rejects a certificate or random text, before any network call', () => {
    expect(looksLikeP8('-----BEGIN CERTIFICATE-----')).toBe(false);
    expect(looksLikeP8('not a key at all')).toBe(false);
  });
});

describe('combineApnsProbes', () => {
  const accepted = explainApnsVerification(400, 'BadDeviceToken');
  const rejected = explainApnsVerification(403, 'InvalidProviderToken');
  const wrongTopic = explainApnsVerification(403, 'TopicDisallowed');

  it('reports both when an older unscoped key works everywhere', () => {
    const result = combineApnsProbes(accepted, accepted);
    expect(result.ok).toBe(true);
    expect(result.scope).toBe('both');
    expect(result.fix).toBeUndefined();
  });

  /**
   * The case that made this necessary. Probing only Sandbox would call a
   * perfectly good Production key "not an APNs key" and send the developer off
   * to regenerate something that was never broken.
   */
  it('accepts a production-only key instead of calling it invalid', () => {
    const result = combineApnsProbes(rejected, accepted);
    expect(result.ok).toBe(true);
    expect(result.scope).toBe('production');
    expect(result.fix).toMatch(/debug builds/i);
  });

  it('accepts a sandbox-only key and warns before shipping', () => {
    const result = combineApnsProbes(accepted, rejected);
    expect(result.ok).toBe(true);
    expect(result.scope).toBe('sandbox');
    expect(result.fix).toMatch(/TestFlight|App Store/);
  });

  it('fails only when neither environment accepts the key', () => {
    const result = combineApnsProbes(rejected, rejected);
    expect(result.ok).toBe(false);
    expect(result.scope).toBeNull();
    expect(result.problem).toBe('not-an-apns-key');
  });

  it('prefers the more specific reason when both reject', () => {
    // A topic mismatch says more than a generic token rejection.
    const result = combineApnsProbes(explainApnsVerification(403, 'Whatever'), wrongTopic);
    expect(result.problem).toBe('wrong-bundle-id');
  });

  it('never reports a scope when it did not succeed', () => {
    expect(combineApnsProbes(rejected, rejected).scope).toBeNull();
  });
});

describe('environment scoping', () => {
  /**
   * Observed live: a Sandbox-scoped key probed against Apple's production host
   * returns BadEnvironmentKeyInToken. Treating that as "not an APNs key" would
   * send someone off to regenerate a key that is perfectly good.
   */
  it('distinguishes the wrong environment from the wrong kind of key', () => {
    const result = explainApnsVerification(403, 'BadEnvironmentKeyInToken');
    if (result.ok) throw new Error('should not be ok');
    expect(result.problem).toBe('wrong-environment');
    expect(result.problem).not.toBe('not-an-apns-key');
    expect(result.fix).toMatch(/Sandbox|Production/);
  });

  it('accepts a sandbox key that production rejects on environment grounds', () => {
    // Exactly the pair returned by a real, freshly created Sandbox key.
    const result = combineApnsProbes(
      explainApnsVerification(400, 'BadDeviceToken'),
      explainApnsVerification(403, 'BadEnvironmentKeyInToken'),
    );
    expect(result.ok).toBe(true);
    expect(result.scope).toBe('sandbox');
  });
});
