/**
 * Turns Apple's APNs rejection reasons into something a developer can act on.
 *
 * This exists because the failure mode it prevents is brutal: the credentials
 * form accepts anything, says "saved", and then every notification silently
 * fails forever. Apple's own reason strings do not help — `InvalidProviderToken`
 * is what you get for uploading an App Store Connect key, and Apple names both
 * kinds of key `AuthKey_XXXXXXXXXX.p8`.
 *
 * The check works by deliberately sending to an invalid device token. A
 * `BadDeviceToken` reply is the *success* case: it means Apple accepted the
 * provider token and only objected to the device.
 */

/** Which APNs hosts accepted the key. */
export type ApnsEnvironmentScope = 'sandbox' | 'production' | 'both';

export type ApnsProblem =
  | 'not-an-apns-key'
  | 'wrong-bundle-id'
  | 'wrong-environment'
  | 'clock-skew'
  | 'rate-limited'
  | 'unreachable'
  | 'unknown';

export type ApnsVerification =
  | { ok: true; detail: string }
  | { ok: false; problem: ApnsProblem; detail: string; fix: string };

/** A device token cannot be this, so Apple always rejects it. */
export const PROBE_DEVICE_TOKEN = 'ff'.repeat(32);

export function explainApnsVerification(
  status: number,
  reason?: string,
): ApnsVerification {
  // Apple got as far as looking at the device token, which means the key, key
  // id, team id and topic were all accepted.
  if (reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic') {
    return { ok: true, detail: 'Apple accepted these credentials.' };
  }

  if (status >= 200 && status < 300) {
    // Should be unreachable: the probe token is not a real device.
    return {
      ok: false,
      problem: 'unknown',
      detail: 'Apple accepted a send to an invalid device token.',
      fix: 'This should not happen. Please report it.',
    };
  }

  switch (reason) {
    case 'InvalidProviderToken':
      return {
        ok: false,
        problem: 'not-an-apns-key',
        detail: 'Apple rejected the key itself.',
        fix:
          'This is usually an App Store Connect or StoreKit key rather than an APNs one — ' +
          'Apple names them all AuthKey_XXXXXXXXXX.p8. Create a key with ' +
          '"Apple Push Notification service" ticked, and check the Team ID matches ' +
          'the team that owns it.',
      };

    /**
     * Observed live against Apple: a Sandbox-scoped key probed against the
     * production host. It means the key is genuine but belongs to the other
     * environment — very different advice from "this is the wrong kind of key".
     */
    case 'BadEnvironmentKeyInToken':
      return {
        ok: false,
        problem: 'wrong-environment',
        detail: 'This key belongs to the other APNs environment.',
        fix:
          'Apple scopes a key to Sandbox or Production. Debug builds installed from ' +
          'Xcode use Sandbox; TestFlight and the App Store use Production.',
      };

    case 'TopicDisallowed':
      return {
        ok: false,
        problem: 'wrong-bundle-id',
        detail: 'The key is valid, but not for this bundle ID.',
        fix: 'Use the bundle identifier of an app in the same team as the key.',
      };

    case 'ExpiredProviderToken':
      return {
        ok: false,
        problem: 'clock-skew',
        detail: 'Apple considered the signed token expired.',
        fix: "Check this machine's clock — APNs rejects tokens more than an hour old.",
      };

    case 'TooManyProviderTokenUpdates':
      return {
        ok: false,
        problem: 'rate-limited',
        detail: 'Apple is rate-limiting token generation.',
        fix: 'Wait a minute and try again.',
      };

    case 'MissingProviderToken':
      return {
        ok: false,
        problem: 'unknown',
        detail: 'No provider token reached Apple.',
        fix: 'This is a Notifie bug rather than a problem with your key.',
      };

    default:
      return {
        ok: false,
        problem: 'unknown',
        detail: `Apple replied ${status}${reason ? ` (${reason})` : ''}.`,
        fix: 'Check the Key ID, Team ID and bundle identifier all belong together.',
      };
  }
}

/** Apple names the download `AuthKey_<KeyID>.p8`; typing it again invites typos. */
export function keyIdFromFilename(filename: string): string | null {
  const match = /^AuthKey_([A-Z0-9]{10})\.p8$/i.exec(filename.trim());
  return match ? match[1]!.toUpperCase() : null;
}

/**
 * Both APNs and App Store Connect keys are named `AuthKey_*.p8`, so the name
 * cannot tell them apart — but the *contents* can be checked for being a
 * PKCS#8 private key at all, which catches a wrong file before a network call.
 */
export function looksLikeP8(contents: string): boolean {
  return /-----BEGIN PRIVATE KEY-----/.test(contents);
}

export const APNS_KEY_PORTAL_URL = 'https://developer.apple.com/account/resources/authkeys/add';
export const APNS_KEY_LIST_URL = 'https://developer.apple.com/account/resources/authkeys/list';
export const APPLE_MEMBERSHIP_URL = 'https://developer.apple.com/account#MembershipDetailsCard';


/**
 * Combines a sandbox probe and a production probe into one verdict.
 *
 * Apple now scopes a key to one environment, so probing only one would report
 * a perfectly good Production key as "not an APNs key" — advice that would send
 * a developer off to regenerate a key that was fine. Probing both also removes
 * a question nobody can reliably answer from memory: debug builds installed
 * from Xcode use Sandbox, TestFlight and the App Store use Production.
 */
export interface DualProbeResult {
  ok: boolean;
  scope: ApnsEnvironmentScope | null;
  detail: string;
  fix?: string;
  problem?: ApnsProblem;
}

export function combineApnsProbes(
  sandbox: ApnsVerification,
  production: ApnsVerification,
): DualProbeResult {
  if (sandbox.ok && production.ok) {
    return {
      ok: true,
      scope: 'both',
      detail: 'Apple accepted this key for development and production builds.',
    };
  }

  if (sandbox.ok) {
    return {
      ok: true,
      scope: 'sandbox',
      detail: 'Apple accepted this key for development builds.',
      fix:
        'This key is scoped to Sandbox, so builds from TestFlight or the App Store ' +
        'will not receive notifications. Create a Production key before you ship.',
    };
  }

  if (production.ok) {
    return {
      ok: true,
      scope: 'production',
      detail: 'Apple accepted this key for production builds.',
      fix:
        'This key is scoped to Production, so debug builds installed from Xcode ' +
        'will not receive notifications — they use Sandbox.',
    };
  }

  // Both rejected. Report the more specific of the two: a topic mismatch says
  // more than a generic token rejection.
  const chosen =
    !production.ok && production.problem !== 'unknown'
      ? production
      : !sandbox.ok && sandbox.problem !== 'unknown'
        ? sandbox
        : production;

  return {
    ok: false,
    scope: null,
    detail: chosen.ok ? 'Apple rejected this key.' : chosen.detail,
    fix: chosen.ok ? undefined : chosen.fix,
    problem: chosen.ok ? 'unknown' : chosen.problem,
  };
}
