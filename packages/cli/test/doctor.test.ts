import { describe, expect, it } from 'vitest';
import {
  checkApiKey,
  checkAuthenticates,
  checkAutomations,
  checkEventsArriving,
  checkPushConfigured,
  checkReachable,
  formatResults,
  summarise,
  type CheckResult,
} from '../src/doctor';

/** A fetch stand-in; no network is touched. */
function fakeFetch(status: number): typeof fetch {
  return (async () => new Response(null, { status })) as unknown as typeof fetch;
}

function fakeStatus(body: unknown, status = 200): typeof fetch {
  return (async () => new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })) as unknown as typeof fetch;
}

const failingFetch = (async () => {
  throw new Error('ECONNREFUSED');
}) as unknown as typeof fetch;

const VALID_KEY = `ntf_live_abcdef123456_${'a'.repeat(40)}`;

describe('checkApiKey', () => {
  it('fails with an actionable fix when no key is configured', () => {
    const result = checkApiKey({});
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('notifie init');
  });

  it('fails on a malformed key', () => {
    const result = checkApiKey({ apiKey: 'nonsense' });
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('ntf_live_');
  });

  it('passes on a valid key without echoing the secret', () => {
    const result = checkApiKey({ apiKey: VALID_KEY });
    expect(result.status).toBe('pass');
    expect(result.message).not.toContain(VALID_KEY);
  });
});

describe('checkReachable', () => {
  it('treats a 400 as reachable, since the endpoint clearly parsed the request', async () => {
    const result = await checkReachable({}, { fetch: fakeFetch(400) });
    expect(result.status).toBe('pass');
  });

  it('fails on a 5xx and says the server is erroring', async () => {
    const result = await checkReachable({}, { fetch: fakeFetch(503) });
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('logs');
  });

  it('fails when the connection is refused', async () => {
    const result = await checkReachable({}, { fetch: failingFetch });
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('Start the server');
  });

  it('rejects generic HTML success and missing routes as a wrong base URL', async () => {
    expect((await checkReachable({}, { fetch: fakeFetch(200) })).status).toBe('fail');
    expect((await checkReachable({}, { fetch: fakeFetch(404) })).status).toBe('fail');
  });
});

describe('checkAuthenticates', () => {
  it('validates the read-only Notifie status response', async () => {
    const result = await checkAuthenticates({ apiKey: VALID_KEY }, {
      fetch: fakeStatus({
        events: 0,
        deviceTokens: 0,
        pushCredentials: [],
        activeAutomations: 0,
        eventNames: [],
      }),
    });
    expect(result.status).toBe('pass');
  });

  it('rejects an unrelated JSON or HTML success response', async () => {
    expect(
      (await checkAuthenticates(
        { apiKey: VALID_KEY },
        { fetch: fakeStatus({ ok: true }) },
      )).status,
    ).toBe('fail');
    expect(
      (await checkAuthenticates(
        { apiKey: VALID_KEY },
        { fetch: fakeStatus('<html>not Notifie</html>') },
      )).status,
    ).toBe('fail');
  });

  it('reports a revoked key clearly', async () => {
    const result = await checkAuthenticates({ apiKey: VALID_KEY }, { fetch: fakeFetch(401) });
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('revoked');
  });

  it('fails when an unexpected status cannot prove authentication', async () => {
    const result = await checkAuthenticates({ apiKey: VALID_KEY }, { fetch: fakeFetch(418) });
    expect(result.status).toBe('fail');
  });

  it('does not attempt a request with no key', async () => {
    let called = false;
    const spy = (async () => {
      called = true;
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;

    const result = await checkAuthenticates({}, { fetch: spy });
    expect(called).toBe(false);
    expect(result.status).toBe('fail');
  });
});

describe('app state checks', () => {
  const base = { eventCount: 0, hasPushCredentials: false, activeFlowCount: 0 };

  it('fails when no events have arrived, and names the exact call to make', () => {
    const result = checkEventsArriving(base);
    expect(result.status).toBe('fail');
    expect(result.fix).toContain('Notifie.track');
  });

  it('passes once events exist', () => {
    expect(checkEventsArriving({ ...base, eventCount: 42 }).status).toBe('pass');
  });

  /** Missing push is a warning, not a failure: everything else still works. */
  it('warns rather than fails when push is unconfigured', () => {
    const result = checkPushConfigured(base);
    expect(result.status).toBe('warn');
    expect(result.message).toContain('cannot deliver');
  });

  it('warns when nothing is automated', () => {
    expect(checkAutomations(base).status).toBe('warn');
    expect(checkAutomations({ ...base, activeFlowCount: 2 }).status).toBe('pass');
  });
});

describe('summarise', () => {
  const result = (status: CheckResult['status']): CheckResult => ({
    name: 'x',
    status,
    message: 'm',
  });

  it('is ok when only warnings are present', () => {
    expect(summarise([result('pass'), result('warn')])).toEqual({
      ok: true,
      failures: 0,
      warnings: 1,
    });
  });

  it('is not ok when anything failed', () => {
    expect(summarise([result('pass'), result('fail')]).ok).toBe(false);
  });

  it('handles an empty list', () => {
    expect(summarise([])).toEqual({ ok: true, failures: 0, warnings: 0 });
  });
});

describe('formatResults', () => {
  it('prints the fix underneath the failing check', () => {
    const output = formatResults([
      { name: 'API key', status: 'fail', message: 'missing', fix: 'run notifie init' },
    ]);

    expect(output).toContain('✗ API key: missing');
    expect(output).toContain('→ run notifie init');
    expect(output).toContain('1 problem to fix');
  });

  it('says everything is fine when it is', () => {
    expect(formatResults([{ name: 'x', status: 'pass', message: 'ok' }])).toContain(
      'Everything looks good',
    );
  });

  it('distinguishes suggestions from problems', () => {
    const output = formatResults([{ name: 'push', status: 'warn', message: 'not set', fix: 'do it' }]);
    expect(output).toContain('1 suggestion');
    expect(output).not.toContain('problem');
  });
});

// ---------------------------------------------------------------------------
// New checks for native configuration (phase 2)
// ---------------------------------------------------------------------------
import {
  checkProjectDetected,
  checkSdkPresent,
  checkFlutterSdkPresent,
  checkMissingHostFile,
  checkIosBackgroundMode,
  checkIosEntitlement,
  checkAndroidPermission,
  checkGoogleServicesJson,
  checkGoogleServicesGradle,
  checkDeviceTokens,
  checkPushCredentialsUploaded,
  checkEventsFlowing,
  fetchRemoteStatus,
} from '../src/doctor';

describe('checkProjectDetected', () => {
  it('passes when a known type is detected', () => {
    expect(checkProjectDetected('expo').status).toBe('pass');
    expect(checkProjectDetected('flutter').status).toBe('pass');
    expect(checkProjectDetected('react-native').status).toBe('pass');
    expect(checkProjectDetected('swift').status).toBe('pass');
    expect(checkProjectDetected('android').status).toBe('pass');
    expect(checkProjectDetected('web').status).toBe('pass');
  });

  it('warns with a non-empty fix when type is unknown', () => {
    const result = checkProjectDetected('unknown');
    expect(result.status).toBe('warn');
    expect(result.fix).toBeTruthy();
  });
});

describe('checkSdkPresent', () => {
  it('passes when a recognized SDK package is in deps', () => {
    expect(checkSdkPresent({ '@notifie-dev/expo': '1.0.0' }).status).toBe('pass');
    expect(checkSdkPresent({ '@notifie-dev/react-native': '1.0.0' }).status).toBe('pass');
    expect(checkSdkPresent({ '@notifie-dev/web': '1.0.0' }).status).toBe('pass');
    expect(checkSdkPresent({ notifie_flutter: '1.0.0' }).status).toBe('pass');
  });

  describe('checkFlutterSdkPresent', () => {
    it('reads the Flutter dependency from pubspec.yaml', () => {
      expect(checkFlutterSdkPresent('dependencies:\n  notifie_flutter: ^0.1.0\n').status)
        .toBe('pass');
      expect(checkFlutterSdkPresent('dependencies:\n  flutter:\n    sdk: flutter\n').status)
        .toBe('fail');
      expect(checkFlutterSdkPresent('custom:\n  notifie_flutter: nope\n').status)
        .toBe('fail');
    });
  });

  describe('checkMissingHostFile', () => {
    it('returns an actionable failure for partial native projects', () => {
      const result = checkMissingHostFile('Info.plist');
      expect(result.status).toBe('fail');
      expect(result.message).toContain('not found');
      expect(result.fix).toContain('notifie init');
    });
  });

  it('fails with a non-empty fix when no SDK is found', () => {
    const result = checkSdkPresent({ react: '18.0.0' });
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });
});

const PLIST_WITH_BACKGROUND_MODE = `<dict>
  <key>UIBackgroundModes</key>
  <array>
    <string>remote-notification</string>
  </array>
</dict>`;

const PLIST_WITHOUT_BACKGROUND_MODE = '<dict><key>CFBundleName</key></dict>';

describe('checkIosBackgroundMode', () => {
  it('passes when remote-notification is present', () => {
    expect(checkIosBackgroundMode(PLIST_WITH_BACKGROUND_MODE).status).toBe('pass');
  });

  it('fails with a non-empty fix when absent', () => {
    const result = checkIosBackgroundMode(PLIST_WITHOUT_BACKGROUND_MODE);
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });

  it('fails malformed files even if they contain the expected string', () => {
    const malformed =
      '<plist><dict><key>UIBackgroundModes</key><array><string>remote-notification</string></array></dict>';
    expect(checkIosBackgroundMode(malformed).message).toContain('malformed');
  });

  it('does not accept background mode text inside a comment', () => {
    const commented =
      '<plist><dict><!-- <key>UIBackgroundModes</key><array><string>remote-notification</string></array> --></dict></plist>';
    expect(checkIosBackgroundMode(commented).status).toBe('fail');
  });
});

const ENTITLEMENTS_WITH_APS_DOC = '<dict><key>aps-environment</key><string>development</string></dict>';
const ENTITLEMENTS_WITHOUT_APS_DOC = '<dict><key>other</key><true/></dict>';

describe('checkIosEntitlement', () => {
  it('passes when aps-environment is present', () => {
    expect(checkIosEntitlement(ENTITLEMENTS_WITH_APS_DOC).status).toBe('pass');
  });

  it('fails with a non-empty fix when absent', () => {
    const result = checkIosEntitlement(ENTITLEMENTS_WITHOUT_APS_DOC);
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });

  it('fails malformed files even if aps-environment is present', () => {
    expect(
      checkIosEntitlement('<plist><dict><key>aps-environment</key></dict>').message,
    ).toContain('malformed');
  });

  it('does not accept aps-environment inside a comment', () => {
    expect(
      checkIosEntitlement(
        '<plist><dict><!-- <key>aps-environment</key><string>development</string> --></dict></plist>',
      ).status,
    ).toBe('fail');
  });
});

const MANIFEST_WITH_NOTIF_PERM =
  '<manifest><uses-permission android:name="android.permission.POST_NOTIFICATIONS" /><application /></manifest>';
const MANIFEST_WITHOUT_NOTIF_PERM = '<manifest><application /></manifest>';

describe('checkAndroidPermission', () => {
  it('passes when POST_NOTIFICATIONS is present', () => {
    expect(checkAndroidPermission(MANIFEST_WITH_NOTIF_PERM).status).toBe('pass');
  });

  it('fails with a non-empty fix when absent', () => {
    const result = checkAndroidPermission(MANIFEST_WITHOUT_NOTIF_PERM);
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });

  it('fails a non-manifest root even if the permission string is present', () => {
    expect(
      checkAndroidPermission(
        '<wrong><uses-permission android:name="android.permission.POST_NOTIFICATIONS" /><application /></wrong>',
      ).message,
    ).toContain('malformed');
  });

  it('does not accept POST_NOTIFICATIONS inside a comment', () => {
    expect(
      checkAndroidPermission(
        '<manifest><!-- <uses-permission android:name="android.permission.POST_NOTIFICATIONS" /> --><application /></manifest>',
      ).status,
    ).toBe('fail');
  });
});

describe('Firebase Android checks', () => {
  const validClientConfig = JSON.stringify({
    project_info: { project_id: 'notifie-demo' },
    client: [{
      client_info: { android_client_info: { package_name: 'com.example.app' } },
    }],
  });

  it('distinguishes missing, malformed, private, and valid JSON', () => {
    expect(checkGoogleServicesJson(null).message).toContain('missing');
    expect(checkGoogleServicesJson('{').message).toContain('not valid JSON');
    expect(checkGoogleServicesJson(JSON.stringify({ type: 'service_account' })).message)
      .toContain('private service-account');
    expect(checkGoogleServicesJson(validClientConfig)).toMatchObject({
      status: 'pass',
      message: 'notifie-demo · com.example.app',
    });
  });

  it('rejects a Firebase client config for another Android package', () => {
    const result = checkGoogleServicesJson(validClientConfig, 'com.example.other');
    expect(result.status).toBe('fail');
    expect(result.message).toContain('com.example.other');
  });

  it('fails when a dynamic applicationId cannot be verified', () => {
    const result = checkGoogleServicesJson(validClientConfig, null, true);
    expect(result.status).toBe('fail');
    expect(result.message).toContain('dynamic');
  });

  it('requires the plugin at both Gradle levels', () => {
    const configuredProject = 'plugins { id("com.google.gms.google-services") version "4.4.2" apply false }';
    const configuredApp = 'plugins { id("com.google.gms.google-services") }';

    expect(checkGoogleServicesGradle(null, configuredApp).status).toBe('fail');
    expect(checkGoogleServicesGradle(configuredProject, null).status).toBe('fail');
    expect(checkGoogleServicesGradle(configuredProject, configuredApp).status).toBe('pass');
  });
});

const STATUS = {
  events: 42,
  deviceTokens: 3,
  pushCredentials: ['apns'],
  activeAutomations: 1,
  eventNames: ['app_open'],
};

describe('fetchRemoteStatus', () => {
  it('returns null without an API key rather than calling the server', async () => {
    let called = false;
    const result = await fetchRemoteStatus({}, {
      fetch: (async () => {
        called = true;
        return new Response('{}', { status: 200 });
      }) as unknown as typeof fetch,
    });
    expect(result).toBeNull();
    expect(called).toBe(false);
  });

  it('returns null on network failure instead of throwing', async () => {
    expect(await fetchRemoteStatus({ apiKey: VALID_KEY }, { fetch: failingFetch })).toBeNull();
  });

  it('returns null on a non-ok response', async () => {
    expect(await fetchRemoteStatus({ apiKey: VALID_KEY }, { fetch: fakeFetch(401) })).toBeNull();
  });

  it('parses the payload on success', async () => {
    const result = await fetchRemoteStatus(
      { apiKey: VALID_KEY },
      { fetch: (async () => new Response(JSON.stringify(STATUS), { status: 200 })) as unknown as typeof fetch },
    );
    expect(result?.deviceTokens).toBe(3);
  });

  it('returns null for malformed success payloads', async () => {
    expect(
      await fetchRemoteStatus(
        { apiKey: VALID_KEY },
        { fetch: fakeStatus({ ok: true }) },
      ),
    ).toBeNull();
    expect(
      await fetchRemoteStatus(
        { apiKey: VALID_KEY },
        { fetch: fakeStatus({ ...STATUS, pushCredentials: ['not-a-provider'] }) },
      ),
    ).toBeNull();
  });
});

describe('remote status checks', () => {
  it('all warn (never fail) when the server is unreachable', () => {
    for (const check of [checkDeviceTokens, checkPushCredentialsUploaded, checkEventsFlowing]) {
      const result = check(null);
      expect(result.status).toBe('warn');
      expect(result.fix).toBeTruthy();
    }
  });

  it('passes every check for a fully configured app', () => {
    expect(checkEventsFlowing(STATUS).status).toBe('pass');
    expect(checkPushCredentialsUploaded(STATUS).status).toBe('pass');
    expect(checkDeviceTokens(STATUS).status).toBe('pass');
  });

  it('fails on missing credentials — nothing can be delivered without them', () => {
    const result = checkPushCredentialsUploaded({ ...STATUS, pushCredentials: [] });
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });

  it('requires credentials for every detected native provider', () => {
    expect(
      checkPushCredentialsUploaded(
        { ...STATUS, pushCredentials: ['apns'] },
        ['apns', 'fcm'],
      ).status,
    ).toBe('fail');
    expect(
      checkPushCredentialsUploaded(
        { ...STATUS, pushCredentials: ['apns', 'fcm'] },
        ['apns', 'fcm'],
      ).status,
    ).toBe('pass');
  });

  it('fails when no events have arrived', () => {
    const result = checkEventsFlowing({ ...STATUS, events: 0 });
    expect(result.status).toBe('fail');
    expect(result.fix).toBeTruthy();
  });

  it('only warns on zero devices — the app may not have run on hardware yet', () => {
    const result = checkDeviceTokens({ ...STATUS, deviceTokens: 0 });
    expect(result.status).toBe('warn');
    expect(result.fix).toContain('physical device');
  });
});
