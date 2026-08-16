import { parseApiKey } from '@notifie-dev/contracts';
import type { ProjectType } from './detect.ts';
import {
  plistHasBackgroundMode,
  entitlementsHasApsEnvironment,
  gradleHasGoogleServicesPlugin,
  hasUnresolvedAndroidApplicationId,
  isStructurallyValidAndroidManifest,
  isStructurallyValidPlist,
  manifestHasNotificationPermission,
  parseAndroidApplicationId,
  parseGoogleServicesJson,
} from './configure.ts';

/**
 * `notifie doctor`.
 *
 * Modelled on `flutter doctor`: every check states what is wrong and the exact
 * next action. A diagnostic that says "failed" without saying what to do is
 * just a slower error message.
 */

export type CheckStatus = 'pass' | 'warn' | 'fail';

export interface CheckResult {
  name: string;
  status: CheckStatus;
  message: string;
  /** The literal next action. Omitted only when the check passed cleanly. */
  fix?: string;
}

export interface DoctorConfig {
  apiKey?: string;
  baseUrl?: string;
}

export interface DoctorDeps {
  fetch: typeof fetch;
  now?: () => number;
}

export const DEFAULT_BASE_URL = 'https://notifie.dev';

export function checkApiKey(config: DoctorConfig): CheckResult {
  if (!config.apiKey) {
    return {
      name: 'API key',
      status: 'fail',
      message: 'No API key configured.',
      fix: 'Run `notifie init` and paste the key from the API Keys page.',
    };
  }

  const parsed = parseApiKey(config.apiKey);
  if (!parsed) {
    return {
      name: 'API key',
      status: 'fail',
      message: 'The configured key is not a valid Notifie key.',
      fix: 'Keys look like ntf_live_<lookup>_<secret>; legacy gk_ keys remain valid.',
    };
  }

  return {
    name: 'API key',
    status: 'pass',
    message: `${parsed.environment} key ending …${parsed.secret.slice(-4)}`,
  };
}

export async function checkReachable(
  config: DoctorConfig,
  deps: DoctorDeps,
): Promise<CheckResult> {
  const baseUrl = config.baseUrl ?? DEFAULT_BASE_URL;

  try {
    const response = await deps.fetch(`${baseUrl}/api/v1/events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ events: [] }),
    });

    // These are the only expected responses to an empty event batch without a
    // valid key. A generic website often returns an HTML 200 for unknown paths;
    // treating that as reachable creates a dangerous false green.
    if (response.status >= 500) {
      return {
        name: 'API reachable',
        status: 'fail',
        message: `${baseUrl} responded ${response.status}.`,
        fix: 'The server is up but erroring. Check its logs.',
      };
    }

    if (![400, 401, 429].includes(response.status)) {
      return {
        name: 'API reachable',
        status: 'fail',
        message: `${baseUrl} returned unexpected status ${response.status}.`,
        fix: 'Check NOTIFIE_URL. It must point to the Notifie server root, without an extra path.',
      };
    }

    return { name: 'API reachable', status: 'pass', message: `${baseUrl} is responding.` };
  } catch {
    return {
      name: 'API reachable',
      status: 'fail',
      message: `Could not reach ${baseUrl}.`,
      fix: 'Start the server, or set NOTIFIE_URL if it lives elsewhere.',
    };
  }
}

export async function checkAuthenticates(
  config: DoctorConfig,
  deps: DoctorDeps,
): Promise<CheckResult> {
  return (await checkAuthenticationStatus(config, deps)).check;
}

export async function checkAuthenticationStatus(
  config: DoctorConfig,
  deps: DoctorDeps,
): Promise<{ check: CheckResult; status: RemoteStatus | null }> {
  if (!config.apiKey) {
    return {
      check: {
        name: 'Key accepted',
        status: 'fail',
        message: 'Skipped — no API key configured.',
        fix: 'Run `notifie init` first.',
      },
      status: null,
    };
  }

  const baseUrl = config.baseUrl ?? DEFAULT_BASE_URL;

  try {
    const response = await deps.fetch(`${baseUrl}/api/v1/status`, {
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
      },
    });

    if (response.status === 401) {
      return {
        check: {
          name: 'Key accepted',
          status: 'fail',
          message: 'The server rejected this API key.',
          fix: 'The key may have been revoked. Create a new one on the API Keys page.',
        },
        status: null,
      };
    }

    if (response.status === 200) {
      const body = await response.json().catch(() => null);
      if (isRemoteStatus(body)) {
        return {
          check: {
            name: 'Key accepted',
            status: 'pass',
            message: 'Authenticated successfully.',
          },
          status: body,
        };
      }
      return {
        check: {
          name: 'Key accepted',
          status: 'fail',
          message: 'The server returned an unexpected success response.',
          fix: 'Check NOTIFIE_URL. It must point to a compatible Notifie server.',
        },
        status: null,
      };
    }

    return {
      check: {
        name: 'Key accepted',
        status: 'fail',
        message: `Unexpected response ${response.status}.`,
        fix: 'The key was not verified. Check NOTIFIE_URL and the server version.',
      },
      status: null,
    };
  } catch {
    return {
      check: {
        name: 'Key accepted',
        status: 'fail',
        message: 'Could not reach the server to verify the key.',
        fix: 'Fix reachability first.',
      },
      status: null,
    };
  }
}

export interface AppState {
  eventCount: number;
  hasPushCredentials: boolean;
  activeFlowCount: number;
}

export function checkEventsArriving(state: AppState): CheckResult {
  if (state.eventCount === 0) {
    return {
      name: 'Events arriving',
      status: 'fail',
      message: 'No events received yet.',
      fix: 'Call Notifie.track("app_open") somewhere in your app and run it once.',
    };
  }

  return {
    name: 'Events arriving',
    status: 'pass',
    message: `${state.eventCount.toLocaleString()} events received.`,
  };
}

export function checkPushConfigured(state: AppState): CheckResult {
  if (!state.hasPushCredentials) {
    return {
      name: 'Push credentials',
      status: 'warn',
      message: 'Not configured — automations will run but cannot deliver.',
      fix: 'Upload your APNs .p8 or FCM service account in Integration → Push Providers.',
    };
  }

  return { name: 'Push credentials', status: 'pass', message: 'Configured.' };
}

export function checkAutomations(state: AppState): CheckResult {
  if (state.activeFlowCount === 0) {
    return {
      name: 'Automations',
      status: 'warn',
      message: 'Nothing is automated yet.',
      fix: 'Run `notifie templates` to see what fits your events.',
    };
  }

  return {
    name: 'Automations',
    status: 'pass',
    message: `${state.activeFlowCount} active.`,
  };
}

// ---------------------------------------------------------------------------
// Native-configuration checks (added in phase 2 of CLI init)
// ---------------------------------------------------------------------------

export function checkProjectDetected(type: ProjectType): CheckResult {
  if (type === 'unknown') {
    return {
      name: 'Project type',
      status: 'warn',
      message: 'Could not detect project type.',
      fix: 'Run `notifie init` from the root of your app directory.',
    };
  }
  return {
    name: 'Project type',
    status: 'pass',
    message: `Detected: ${type}`,
  };
}

/** Pass `pkg.dependencies` merged with `pkg.devDependencies`. */
export function checkSdkPresent(deps: Record<string, unknown>): CheckResult {
  const sdkPackages = [
    '@notifie-dev/react-native',
    '@notifie-dev/web',
    '@notifie-dev/expo',
    '@notifie-dev/react-native',
    '@notifie-dev/web',
    '@notifie-dev/expo',
    'notifie_flutter',
    'notifie_flutter',
  ];
  const found = sdkPackages.find((p) => p in deps);
  if (!found) {
    return {
      name: 'SDK dependency',
      status: 'fail',
      message: 'No Notifie SDK found in dependencies.',
      fix: 'Add the Notifie SDK package for this platform, then rerun `notifie doctor`.',
    };
  }

  return {
    name: 'SDK dependency',
    status: 'pass',
    message: `Found ${found}`,
  };
}

export function checkFlutterSdkPresent(pubspecContent: string): CheckResult {
  const block = /^dependencies\s*:\s*(?:#.*)?\n((?:[ \t]+.*(?:\n|$)|[ \t]*\n)*)/m
    .exec(pubspecContent)?.[1];
  const inline = /^dependencies\s*:\s*\{([^}]*)\}/m.exec(pubspecContent)?.[1];
  const packageName = ['notifie_flutter', 'notifie_flutter'].find((name) => (
    (block !== undefined && new RegExp(`^[ \\t]+${name}\\s*:`, 'm').test(block))
    || (inline !== undefined && new RegExp(`(?:^|,)\\s*${name}\\s*:`).test(inline))
  ));
  const found = packageName !== undefined;
  if (!found) {
    return {
      name: 'SDK dependency',
      status: 'fail',
      message: 'notifie_flutter is missing from pubspec.yaml.',
      fix: 'Add notifie_flutter under dependencies, then run `flutter pub get`.',
    };
  }
  return {
    name: 'SDK dependency',
    status: 'pass',
    message: `Found ${packageName}`,
  };
}

export function checkMissingHostFile(
  name: 'Info.plist' | 'entitlements' | 'AndroidManifest.xml',
): CheckResult {
  return {
    name: name === 'AndroidManifest.xml' ? 'Android host config' : `iOS ${name}`,
    status: 'fail',
    message: `${name} was not found in the native host project.`,
    fix: 'Restore or generate the native host project, then rerun `notifie init` and `notifie doctor`.',
  };
}

/** Pass the raw content of the project's Info.plist. */
export function checkIosBackgroundMode(infoPlistContent: string): CheckResult {
  if (!isStructurallyValidPlist(infoPlistContent)) {
    return {
      name: 'iOS background mode',
      status: 'fail',
      message: 'Info.plist is malformed.',
      fix: 'Repair Info.plist in Xcode, then rerun `notifie doctor`.',
    };
  }
  if (!plistHasBackgroundMode(infoPlistContent)) {
    return {
      name: 'iOS background mode',
      status: 'fail',
      message: 'UIBackgroundModes does not include remote-notification.',
      fix: 'Run `notifie init` to add it, or add it in Info.plist manually.',
    };
  }
  return {
    name: 'iOS background mode',
    status: 'pass',
    message: 'remote-notification present.',
  };
}

/** Pass the raw content of the project's entitlements file. */
export function checkIosEntitlement(entitlementsContent: string): CheckResult {
  if (!isStructurallyValidPlist(entitlementsContent)) {
    return {
      name: 'iOS entitlement',
      status: 'fail',
      message: 'The entitlements plist is malformed.',
      fix: 'Repair the entitlements file in Xcode, then rerun `notifie doctor`.',
    };
  }
  if (!entitlementsHasApsEnvironment(entitlementsContent)) {
    return {
      name: 'iOS entitlement',
      status: 'fail',
      message: 'aps-environment entitlement is missing.',
      fix: 'Add Push Notifications in Xcode (Target → Signing & Capabilities).',
    };
  }
  return {
    name: 'iOS entitlement',
    status: 'pass',
    message: 'aps-environment present.',
  };
}

/** Pass the raw content of AndroidManifest.xml. */
export function checkAndroidPermission(manifestContent: string): CheckResult {
  if (!isStructurallyValidAndroidManifest(manifestContent)) {
    return {
      name: 'Android permission',
      status: 'fail',
      message: 'AndroidManifest.xml is malformed.',
      fix: 'Repair AndroidManifest.xml, then rerun `notifie doctor`.',
    };
  }
  if (!manifestHasNotificationPermission(manifestContent)) {
    return {
      name: 'Android permission',
      status: 'fail',
      message: 'POST_NOTIFICATIONS permission is missing (required from API 33).',
      fix: 'Run `notifie init` to add it, or add it in AndroidManifest.xml manually.',
    };
  }
  return {
    name: 'Android permission',
    status: 'pass',
    message: 'POST_NOTIFICATIONS present.',
  };
}

export function checkGoogleServicesJson(
  content: string | null,
  expectedPackage?: string | null,
  packageIndeterminate = false,
): CheckResult {
  if (content === null) {
    return {
      name: 'Firebase app config',
      status: 'fail',
      message: 'google-services.json is missing from the Android app module.',
      fix: 'Download the Android app config from Firebase Console and rerun `notifie init YOUR_SDK_INGEST_KEY --yes`.',
    };
  }

  try {
    const json = JSON.parse(content) as { type?: unknown };
    if (json.type === 'service_account') {
      return {
        name: 'Firebase app config',
        status: 'fail',
        message: 'A private service-account key was placed in the Android app.',
        fix: 'Remove it immediately. Download google-services.json from Project settings → General; upload the private key only in Notifie.',
      };
    }
  } catch {
    return {
      name: 'Firebase app config',
      status: 'fail',
      message: 'google-services.json is not valid JSON.',
      fix: 'Download a fresh Android app config from Firebase Console → Project settings → General.',
    };
  }

  const info = parseGoogleServicesJson(content);
  if (!info) {
    return {
      name: 'Firebase app config',
      status: 'fail',
      message: 'The JSON is not a Firebase Android app configuration.',
      fix: 'Use google-services.json from Firebase Project settings → General, not a service-account key.',
    };
  }

  if (packageIndeterminate) {
    return {
      name: 'Firebase app config',
      status: 'fail',
      message: 'The Android applicationId is dynamic, so the Firebase package cannot be verified.',
      fix: 'Resolve the app module applicationId and confirm google-services.json contains that exact package.',
    };
  }

  if (expectedPackage && !info.packages.includes(expectedPackage)) {
    return {
      name: 'Firebase app config',
      status: 'fail',
      message:
        `google-services.json is for ${info.packages.join(', ')}, not ${expectedPackage}.`,
      fix:
        'Download google-services.json for the app module applicationId from Firebase Console.',
    };
  }

  return {
    name: 'Firebase app config',
    status: 'pass',
    message: `${info.projectId} · ${info.packages.join(', ')}`,
  };
}

export function androidApplicationId(appGradleContent: string | null): string | null {
  return appGradleContent ? parseAndroidApplicationId(appGradleContent) : null;
}

export function androidApplicationIdIsDynamic(appGradleContent: string | null): boolean {
  return appGradleContent
    ? hasUnresolvedAndroidApplicationId(appGradleContent)
    : false;
}

export function checkGoogleServicesGradle(
  projectGradleContent: string | null,
  appGradleContent: string | null,
): CheckResult {
  const projectConfigured = projectGradleContent !== null &&
    gradleHasGoogleServicesPlugin(projectGradleContent, 'project');
  const appConfigured = appGradleContent !== null &&
    gradleHasGoogleServicesPlugin(appGradleContent, 'app');

  if (!projectConfigured || !appConfigured) {
    const missing = [
      !projectConfigured ? 'project declaration' : null,
      !appConfigured ? 'app-module application' : null,
    ].filter(Boolean).join(' and ');
    return {
      name: 'Firebase Gradle plugin',
      status: 'fail',
      message: `Missing ${missing}.`,
      fix: 'Run `notifie init YOUR_SDK_INGEST_KEY --yes` after adding google-services.json.',
    };
  }

  return {
    name: 'Firebase Gradle plugin',
    status: 'pass',
    message: 'Declared by the project and applied to the app module.',
  };
}

/**
 * Setup state reported by the server for this API key.
 *
 * One request rather than several: the checks below all answer questions about
 * the same app, and asking three times would be three round trips for a command
 * a developer runs while waiting.
 */
export interface RemoteStatus {
  events: number;
  deviceTokens: number;
  pushCredentials: string[];
  activeAutomations: number;
  eventNames: string[];
}

function isRemoteStatus(value: unknown): value is RemoteStatus {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  const status = value as Record<string, unknown>;
  return Number.isInteger(status.events) && (status.events as number) >= 0 &&
    Number.isInteger(status.deviceTokens) && (status.deviceTokens as number) >= 0 &&
    Number.isInteger(status.activeAutomations) &&
    (status.activeAutomations as number) >= 0 &&
    Array.isArray(status.pushCredentials) &&
    status.pushCredentials.every(
      (provider) => provider === 'apns' || provider === 'fcm',
    ) &&
    Array.isArray(status.eventNames) &&
    status.eventNames.every((name) => typeof name === 'string');
}

export async function fetchRemoteStatus(
  config: DoctorConfig,
  deps: DoctorDeps,
): Promise<RemoteStatus | null> {
  if (!config.apiKey) return null;

  try {
    const response = await deps.fetch(`${config.baseUrl ?? DEFAULT_BASE_URL}/api/v1/status`, {
      headers: { Authorization: `Bearer ${config.apiKey}` },
    });

    if (!response.ok) return null;
    const body = await response.json();
    return isRemoteStatus(body) ? body : null;
  } catch {
    return null;
  }
}

/**
 * Absent tokens are a warning, not a failure: it usually means the app has not
 * been run on a real device yet, and simulators cannot receive push at all.
 */
export function checkDeviceTokens(status: RemoteStatus | null): CheckResult {
  if (!status) {
    return {
      name: 'Device tokens',
      status: 'warn',
      message: 'Could not reach the server to check.',
      fix: 'Fix reachability and the API key first.',
    };
  }

  if (status.deviceTokens === 0) {
    return {
      name: 'Device tokens',
      status: 'warn',
      message: 'No devices registered yet.',
      fix: 'Call the SDK notification-enrollment API and run the app on a physical device for definitive delivery testing.',
    };
  }

  return {
    name: 'Device tokens',
    status: 'pass',
    message: `${status.deviceTokens} device${status.deviceTokens === 1 ? '' : 's'} registered.`,
  };
}

export function checkPushCredentialsUploaded(
  status: RemoteStatus | null,
  requiredProviders: Array<'apns' | 'fcm'> = [],
): CheckResult {
  if (!status) {
    return {
      name: 'Push credentials',
      status: 'warn',
      message: 'Could not reach the server to check.',
      fix: 'Fix reachability and the API key first.',
    };
  }

  if (status.pushCredentials.length === 0) {
    return {
      name: 'Push credentials',
      status: 'fail',
      message: 'None uploaded — nothing can be delivered.',
      fix: 'Upload APNs credentials for iOS and/or an FCM service account for Android in Integration → Push Providers.',
    };
  }
  const missing = requiredProviders.filter(
    (provider) => !status.pushCredentials.includes(provider),
  );
  if (missing.length > 0) {
    return {
      name: 'Push credentials',
      status: 'fail',
      message: `Missing ${missing.join(' and ')} credentials for the detected native host.`,
      fix: 'Configure every detected mobile platform in Integration → Push Providers.',
    };
  }
  return {
    name: 'Push credentials',
    status: 'pass',
    message: `${status.pushCredentials.join(', ')} configured.`,
  };
}

export function checkEventsFlowing(status: RemoteStatus | null): CheckResult {
  if (!status) {
    return {
      name: 'Events arriving',
      status: 'warn',
      message: 'Could not reach the server to check.',
      fix: 'Fix reachability and the API key first.',
    };
  }

  if (status.events === 0) {
    return {
      name: 'Events arriving',
      status: 'fail',
      message: 'No events received yet.',
      fix: 'Call Notifie.initialize() and run your app once — app_open and install are tracked for you.',
    };
  }

  return {
    name: 'Events arriving',
    status: 'pass',
    message: `${status.events.toLocaleString()} events received.`,
  };
}

export function summarise(results: CheckResult[]): {
  ok: boolean;
  failures: number;
  warnings: number;
} {
  const failures = results.filter((r) => r.status === 'fail').length;
  const warnings = results.filter((r) => r.status === 'warn').length;
  return { ok: failures === 0, failures, warnings };
}

const ICON: Record<CheckStatus, string> = { pass: '✓', warn: '!', fail: '✗' };

export function formatResults(results: CheckResult[]): string {
  const lines = results.map((result) => {
    const head = `  ${ICON[result.status]} ${result.name}: ${result.message}`;
    return result.fix ? `${head}\n      → ${result.fix}` : head;
  });

  const { ok, failures, warnings } = summarise(results);
  const verdict = ok
    ? warnings > 0
      ? `Ready, with ${warnings} suggestion${warnings === 1 ? '' : 's'}.`
      : 'Everything looks good.'
    : `${failures} problem${failures === 1 ? '' : 's'} to fix.`;

  return `${lines.join('\n')}\n\n  ${verdict}`;
}
