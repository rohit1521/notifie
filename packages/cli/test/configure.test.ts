import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import {
  plistHasBackgroundMode,
  plistAddBackgroundMode,
  entitlementsHasApsEnvironment,
  entitlementsAddApsEnvironment,
  manifestHasNotificationPermission,
  manifestAddNotificationPermission,
  expoHasBackgroundMode,
  expoAddPushConfig,
  hasUnresolvedAndroidApplicationId,
  parseAndroidApplicationId,
  parseGoogleServicesJson,
  gradleAddGoogleServicesPlugin,
  gradleHasGoogleServicesPlugin,
  planChanges,
} from '../src/configure';
import type { ProjectInfo } from '../src/detect';

// ---------------------------------------------------------------------------
// Pure content-transformation tests (no filesystem)
// ---------------------------------------------------------------------------

const PLIST_WITH_BG_MODE = `<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>UIBackgroundModes</key>
  <array>
    <string>remote-notification</string>
  </array>
</dict>`;

const PLIST_WITHOUT_BG_MODE = `<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>SomeKey</key>
  <string>value</string>
</dict>`;

const PLIST_WITH_OTHER_BG_MODE = `<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>UIBackgroundModes</key>
  <array>
    <string>fetch</string>
  </array>
</dict>`;

describe('plistHasBackgroundMode', () => {
  it('returns true when remote-notification is already present', () => {
    expect(plistHasBackgroundMode(PLIST_WITH_BG_MODE)).toBe(true);
  });

  it('does not duplicate a wrong-typed UIBackgroundModes key', () => {
    const content =
      '<plist><dict><key>UIBackgroundModes</key><string>remote-notification</string></dict></plist>';
    expect(plistAddBackgroundMode(content)).toBe(content);
    expect(plistHasBackgroundMode(content)).toBe(false);
  });

  it('returns false when the key is absent', () => {
    expect(plistHasBackgroundMode(PLIST_WITHOUT_BG_MODE)).toBe(false);
  });

  it('does not accept or duplicate a wrong-typed aps-environment', () => {
    const content =
      '<plist><dict><key>aps-environment</key><true/></dict></plist>';
    expect(entitlementsHasApsEnvironment(content)).toBe(false);
    expect(entitlementsAddApsEnvironment(content)).toBe(content);
  });

  it('returns false when UIBackgroundModes exists but lacks remote-notification', () => {
    expect(plistHasBackgroundMode(PLIST_WITH_OTHER_BG_MODE)).toBe(false);
  });

  it('ignores settings that exist only inside XML comments', () => {
    expect(
      plistHasBackgroundMode(
        '<plist><dict><!-- <key>UIBackgroundModes</key><array><string>remote-notification</string></array> --></dict></plist>',
      ),
    ).toBe(false);
  });

  it('inserts outside commented plist markers', () => {
    const content =
      '<plist><dict><!-- <key>UIBackgroundModes</key><array></array></dict> --></dict></plist>';
    const result = plistAddBackgroundMode(content);
    expect(plistHasBackgroundMode(result)).toBe(true);
    expect(result).toContain('<!-- <key>UIBackgroundModes');
  });
});

describe('plistAddBackgroundMode', () => {
  it('adds remote-notification when the key is absent', () => {
    const result = plistAddBackgroundMode(PLIST_WITHOUT_BG_MODE);
    expect(result).toContain('remote-notification');
    expect(result).toContain('UIBackgroundModes');
    // Original key should be preserved.
    expect(result).toContain('SomeKey');
  });

  it('appends to an existing array without removing other entries', () => {
    const result = plistAddBackgroundMode(PLIST_WITH_OTHER_BG_MODE);
    expect(result).toContain('remote-notification');
    expect(result).toContain('fetch');
  });

  it('is idempotent — running twice does not duplicate the entry', () => {
    const once = plistAddBackgroundMode(PLIST_WITHOUT_BG_MODE);
    const twice = plistAddBackgroundMode(once);
    const count = (twice.match(/remote-notification/g) ?? []).length;
    expect(count).toBe(1);
  });

  it('is idempotent on a plist that already has the mode', () => {
    const result = plistAddBackgroundMode(PLIST_WITH_BG_MODE);
    expect(result).toBe(PLIST_WITH_BG_MODE);
  });
});

const ENTITLEMENTS_WITH_APS = `<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>aps-environment</key>
  <string>development</string>
</dict>`;

const ENTITLEMENTS_WITHOUT_APS = `<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>`;

describe('entitlementsHasApsEnvironment', () => {
  it('returns true when aps-environment is present', () => {
    expect(entitlementsHasApsEnvironment(ENTITLEMENTS_WITH_APS)).toBe(true);
  });

  it('returns false when absent', () => {
    expect(entitlementsHasApsEnvironment(ENTITLEMENTS_WITHOUT_APS)).toBe(false);
  });

  it('ignores aps-environment inside comments', () => {
    expect(
      entitlementsHasApsEnvironment(
        '<plist><dict><!-- <key>aps-environment</key><string>development</string> --></dict></plist>',
      ),
    ).toBe(false);
  });

  it('inserts entitlement outside commented closing tags', () => {
    const content =
      '<plist><dict><!-- </dict><key>aps-environment</key> --></dict></plist>';
    const result = entitlementsAddApsEnvironment(content);
    expect(entitlementsHasApsEnvironment(result)).toBe(true);
  });
});

describe('entitlementsAddApsEnvironment', () => {
  it('adds aps-environment when absent', () => {
    const result = entitlementsAddApsEnvironment(ENTITLEMENTS_WITHOUT_APS);
    expect(result).toContain('aps-environment');
    expect(result).toContain('com.apple.security.app-sandbox');
  });

  it('is idempotent', () => {
    const once = entitlementsAddApsEnvironment(ENTITLEMENTS_WITHOUT_APS);
    const twice = entitlementsAddApsEnvironment(once);
    const count = (twice.match(/aps-environment/g) ?? []).length;
    expect(count).toBe(1);
  });
});

const MANIFEST_WITH_PERM = `<manifest>
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
</manifest>`;

const MANIFEST_WITHOUT_PERM = `<manifest>
  <uses-permission android:name="android.permission.INTERNET" />
  <application></application>
</manifest>`;

describe('manifestHasNotificationPermission', () => {
  it('returns true when POST_NOTIFICATIONS is present', () => {
    expect(manifestHasNotificationPermission(MANIFEST_WITH_PERM)).toBe(true);
  });

  it('returns false when absent', () => {
    expect(manifestHasNotificationPermission(MANIFEST_WITHOUT_PERM)).toBe(false);
  });

  it('ignores permissions inside comments', () => {
    expect(
      manifestHasNotificationPermission(
        '<manifest><!-- <uses-permission android:name="android.permission.POST_NOTIFICATIONS" /> --><application /></manifest>',
      ),
    ).toBe(false);
  });

  it('inserts permission outside commented manifest nodes', () => {
    const content =
      '<manifest><!-- <uses-permission android:name="android.permission.POST_NOTIFICATIONS" /> --><application /></manifest>';
    const result = manifestAddNotificationPermission(content);
    expect(manifestHasNotificationPermission(result)).toBe(true);
  });
});

const GOOGLE_SERVICES_JSON = JSON.stringify({
  project_info: { project_id: 'notifie-demo' },
  client: [{
    client_info: { android_client_info: { package_name: 'com.example.app' } },
  }],
});

describe('Firebase Android configuration', () => {
  it('distinguishes Android client config from a service-account key', () => {
    expect(parseGoogleServicesJson(GOOGLE_SERVICES_JSON)).toEqual({
      projectId: 'notifie-demo',
      packages: ['com.example.app'],
    });
    expect(parseGoogleServicesJson(JSON.stringify({
      type: 'service_account',
      project_id: 'notifie-demo',
      private_key: 'secret',
    }))).toBeNull();
  });

  it('adds Kotlin Gradle plugin declarations idempotently', () => {
    const project = gradleAddGoogleServicesPlugin('plugins {\n}\n', 'project', true);
    const app = gradleAddGoogleServicesPlugin('plugins {\n}\n', 'app', true);

    expect(project).toContain('version "4.4.2" apply false');
    expect(app).toContain('id("com.google.gms.google-services")');
    expect(gradleAddGoogleServicesPlugin(project, 'project', true)).toBe(project);
    expect(gradleHasGoogleServicesPlugin(app)).toBe(true);
  });

  it('adds Groovy Gradle plugin declarations idempotently', () => {
    const project = gradleAddGoogleServicesPlugin('plugins {\n}\n', 'project', false);
    const app = gradleAddGoogleServicesPlugin("apply plugin: 'com.android.application'\n", 'app', false);

    expect(project).toContain("id 'com.google.gms.google-services'");
    expect(app).toContain("apply plugin: 'com.google.gms.google-services'");
    expect(gradleAddGoogleServicesPlugin(app, 'app', false)).toBe(app);
  });

  it('ignores commented plugins and apply-false in the app module', () => {
    expect(
      gradleHasGoogleServicesPlugin(
        '// id("com.google.gms.google-services")\nplugins {}',
        'app',
      ),
    ).toBe(false);
    expect(
      gradleHasGoogleServicesPlugin(
        'plugins { id("com.google.gms.google-services") apply false }',
        'app',
      ),
    ).toBe(false);
    expect(
      gradleHasGoogleServicesPlugin(
        'plugins { id("com.google.gms.google-services") }',
        'app',
      ),
    ).toBe(true);
  });
});

describe('manifestAddNotificationPermission', () => {
  it('adds the permission after existing uses-permission elements', () => {
    const result = manifestAddNotificationPermission(MANIFEST_WITHOUT_PERM);
    expect(result).toContain('POST_NOTIFICATIONS');
    expect(result).toContain('INTERNET');
    // POST_NOTIFICATIONS should appear after INTERNET
    expect(result.indexOf('INTERNET')).toBeLessThan(result.indexOf('POST_NOTIFICATIONS'));
  });

  it('is idempotent — permission appears exactly once', () => {
    const once = manifestAddNotificationPermission(MANIFEST_WITHOUT_PERM);
    const twice = manifestAddNotificationPermission(once);
    const count = (twice.match(/POST_NOTIFICATIONS/g) ?? []).length;
    expect(count).toBe(1);
  });

  it('inserts before <application when no uses-permission exists', () => {
    const bare = '<manifest>\n  <application></application>\n</manifest>';
    const result = manifestAddNotificationPermission(bare);
    expect(result).toContain(
      '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n' +
      '  <application>',
    );
    expect(result.indexOf('POST_NOTIFICATIONS')).toBeLessThan(result.indexOf('<application'));
  });
});

describe('expoAddPushConfig', () => {
  it('preserves unrelated keys', () => {
    const input = {
      expo: {
        name: 'MyApp',
        slug: 'my-app',
        ios: { bundleIdentifier: 'com.example.app' },
      },
    };
    const result = expoAddPushConfig(input);
    expect((result.expo as { name: string }).name).toBe('MyApp');
    expect((result.expo as { slug: string }).slug).toBe('my-app');
    const ios = (result.expo as { ios: { bundleIdentifier: string } }).ios;
    expect(ios.bundleIdentifier).toBe('com.example.app');
  });

  describe('parseAndroidApplicationId', () => {
    it('reads Kotlin and Groovy applicationId syntax', () => {
      expect(parseAndroidApplicationId('applicationId = "com.example.kotlin"'))
        .toBe('com.example.kotlin');
      expect(parseAndroidApplicationId("applicationId 'com.example.groovy'"))
        .toBe('com.example.groovy');
      expect(parseAndroidApplicationId('android { namespace = "com.example.namespace" }'))
        .toBe('com.example.namespace');
      expect(
        parseAndroidApplicationId(
          '// applicationId = "com.example.stale"\napplicationId = "com.example.real"',
        ),
      ).toBe('com.example.real');
      expect(
        parseAndroidApplicationId(
          'namespace = "com.example.real" // applicationId = "com.example.stale"',
        ),
      ).toBe('com.example.real');
      const dynamic =
        'android { namespace = "com.example.namespace"; applicationId = providers.gradleProperty("APP_ID").get() }';
      expect(parseAndroidApplicationId(dynamic)).toBeNull();
      expect(hasUnresolvedAndroidApplicationId(dynamic)).toBe(true);
    });
  });

  it('adds UIBackgroundModes, aps-environment, and POST_NOTIFICATIONS', () => {
    const result = expoAddPushConfig({ expo: {} });
    const expo = result.expo as {
      ios: {
        infoPlist: { UIBackgroundModes: string[] };
        entitlements: Record<string, unknown>;
      };
      android: { permissions: string[] };
    };
    expect(expo.ios.infoPlist.UIBackgroundModes).toContain('remote-notification');
    expect(expo.ios.entitlements['aps-environment']).toBe('development');
    expect(expo.android.permissions).toContain('android.permission.POST_NOTIFICATIONS');
  });

  it('is idempotent — arrays have no duplicates on second call', () => {
    const once = expoAddPushConfig({ expo: {} });
    const twice = expoAddPushConfig(once);
    const expo = twice.expo as { ios: { infoPlist: { UIBackgroundModes: string[] } }; android: { permissions: string[] } };
    expect(expo.ios.infoPlist.UIBackgroundModes.filter((m) => m === 'remote-notification').length).toBe(1);
    expect(expo.android.permissions.filter((p) => p === 'android.permission.POST_NOTIFICATIONS').length).toBe(1);
  });

  it('does not mutate the input object', () => {
    const input = { expo: { ios: { infoPlist: {} } } };
    expoAddPushConfig(input);
    expect((input.expo.ios.infoPlist as Record<string, unknown>)['UIBackgroundModes']).toBeUndefined();
  });

  it('expoHasBackgroundMode reflects the change', () => {
    const before = { expo: {} };
    expect(expoHasBackgroundMode(before)).toBe(false);
    const after = expoAddPushConfig(before);
    expect(expoHasBackgroundMode(after)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// planChanges: filesystem-touching scenario
// ---------------------------------------------------------------------------

let tmpDir = '';

beforeEach(() => {
  tmpDir = mkdtempSync(join(import.meta.dirname, '..', 'fixtures-'));
});

afterEach(() => {
  rmSync(tmpDir, { recursive: true, force: true });
});

function write(relativePath: string, content: string): void {
  const full = join(tmpDir, relativePath);
  mkdirSync(join(full, '..'), { recursive: true });
  writeFileSync(full, content, 'utf8');
}

describe('planChanges — swift project', () => {
  it('produces only manual changes (no apply) for a raw Xcode project', () => {
    const info: ProjectInfo = { type: 'swift', paths: {} };
    const changes = planChanges(info);
    expect(changes.length).toBeGreaterThan(0);
    for (const change of changes) {
      expect(change.apply).toBeUndefined();
      expect(change.manualInstructions).toBeTruthy();
    }
  });

  it('does not require AppDelegate forwarding for Swift push', () => {
    const appDelegate = join(tmpDir, 'AppDelegate.swift');
    writeFileSync(appDelegate, 'final class AppDelegate {}', 'utf8');

    const changes = planChanges({ type: 'swift', paths: { appDelegate } });
    expect(changes.some((change) => change.file === appDelegate)).toBe(false);
  });

  it('does NOT write any file for a swift project', () => {
    // Create a sentinel file — planChanges must not touch it.
    const sentinel = join(tmpDir, 'project.pbxproj');
    const originalContent = 'ORIGINAL';
    writeFileSync(sentinel, originalContent, 'utf8');

    const info: ProjectInfo = { type: 'swift', paths: {} };
    planChanges(info);

    // File must be byte-identical after planChanges returns.
    expect(readFileSync(sentinel, 'utf8')).toBe(originalContent);
  });
});

describe('planChanges — expo project (app.json)', () => {
  it('apply() writes the expected config and the change is idempotent', () => {
    const appJsonPath = join(tmpDir, 'app.json');
    writeFileSync(appJsonPath, JSON.stringify({ expo: { name: 'Test' } }, null, 2) + '\n', 'utf8');

    const info: ProjectInfo = { type: 'expo', paths: { appJson: appJsonPath } };
    const changes = planChanges(info);
    const appJsonChange = changes.find((c) => c.file === appJsonPath);
    expect(appJsonChange).toBeDefined();
    expect(appJsonChange!.apply).toBeInstanceOf(Function);
    expect(changes.some((change) => change.file === 'project.pbxproj')).toBe(false);

    // Apply once.
    appJsonChange!.apply!();
    const after1 = JSON.parse(readFileSync(appJsonPath, 'utf8')) as { expo: { name: string } };
    expect(after1.expo.name).toBe('Test'); // original key preserved

    // Re-plan and apply again — should be idempotent.
    const changes2 = planChanges(info);
    const change2 = changes2.find((c) => c.file === appJsonPath)!;
    change2.apply!();
    const after2 = readFileSync(appJsonPath, 'utf8');
    expect(after2).toBe(readFileSync(appJsonPath, 'utf8')); // same content
    const count = (after2.match(/remote-notification/g) ?? []).length;
    expect(count).toBe(1);
  });
});

describe('planChanges — react-native project (native files)', () => {
  it('Info.plist change is safe (has apply) and is idempotent', () => {
    const plistPath = join(tmpDir, 'Info.plist');
    writeFileSync(plistPath, PLIST_WITHOUT_BG_MODE, 'utf8');

    const info: ProjectInfo = {
      type: 'react-native',
      paths: { infoPlist: plistPath },
    };
    const changes = planChanges(info);
    const plistChange = changes.find((c) => c.file === plistPath);
    expect(plistChange?.apply).toBeInstanceOf(Function);

    plistChange!.apply!();
    const after1 = readFileSync(plistPath, 'utf8');
    expect(after1).toContain('remote-notification');
    expect(after1).toContain('SomeKey');

    // Second apply — no duplication.
    plistChange!.apply!();
    const after2 = readFileSync(plistPath, 'utf8');
    expect((after2.match(/remote-notification/g) ?? []).length).toBe(1);
  });

  it('does not claim malformed native files were safely edited', () => {
    const plistPath = join(tmpDir, 'Info.plist');
    const entitlementsPath = join(tmpDir, 'App.entitlements');
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    writeFileSync(plistPath, '<plist><broken>', 'utf8');
    writeFileSync(entitlementsPath, '<plist><broken>', 'utf8');
    writeFileSync(manifestPath, '<not-manifest />', 'utf8');

    const changes = planChanges({
      type: 'react-native',
      paths: {
        infoPlist: plistPath,
        entitlements: entitlementsPath,
        androidManifest: manifestPath,
      },
    });

    for (const path of [plistPath, entitlementsPath, manifestPath]) {
      const change = changes.find((candidate) => candidate.file === path);
      expect(change?.apply).toBeUndefined();
      expect(change?.manualInstructions).toContain('malformed');
    }
  });

  it('rejects malformed roots even when insertion markers exist', () => {
    const plistPath = join(tmpDir, 'Info.plist');
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    writeFileSync(plistPath, '<plist><dict></dict>', 'utf8');
    writeFileSync(
      manifestPath,
      '<not-manifest><application /></not-manifest>',
      'utf8',
    );

    const changes = planChanges({
      type: 'react-native',
      paths: { infoPlist: plistPath, androidManifest: manifestPath },
    });

    expect(changes.find((change) => change.file === plistPath)?.apply).toBeUndefined();
    expect(changes.find((change) => change.file === manifestPath)?.apply).toBeUndefined();
  });

  it('rejects unclosed nested XML elements', () => {
    const plistPath = join(tmpDir, 'Info.plist');
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    writeFileSync(
      plistPath,
      '<plist><dict><key>UIBackgroundModes</key><array><string>fetch</string></dict></plist>',
      'utf8',
    );
    writeFileSync(
      manifestPath,
      '<manifest><application><activity></application></manifest>',
      'utf8',
    );

    const changes = planChanges({
      type: 'react-native',
      paths: { infoPlist: plistPath, androidManifest: manifestPath },
    });

    expect(changes.find((change) => change.file === plistPath)?.apply).toBeUndefined();
    expect(changes.find((change) => change.file === manifestPath)?.apply).toBeUndefined();
  });

  it('rejects extra roots and unterminated comments', () => {
    const plistPath = join(tmpDir, 'Info.plist');
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    writeFileSync(plistPath, '<dict></dict><dict></dict>', 'utf8');
    writeFileSync(
      manifestPath,
      '<manifest><application /><!-- unterminated</manifest>',
      'utf8',
    );

    const changes = planChanges({
      type: 'react-native',
      paths: { infoPlist: plistPath, androidManifest: manifestPath },
    });

    expect(changes.find((change) => change.file === plistPath)?.apply).toBeUndefined();
    expect(changes.find((change) => change.file === manifestPath)?.apply).toBeUndefined();
  });

  it('reports missing files inside partial native directories', () => {
    const packageJson = join(tmpDir, 'package.json');
    writeFileSync(packageJson, '{}', 'utf8');
    mkdirSync(join(tmpDir, 'ios'), { recursive: true });
    mkdirSync(join(tmpDir, 'android'), { recursive: true });

    const changes = planChanges({
      type: 'react-native',
      paths: { packageJson },
    });

    expect(changes.some((change) => change.file.includes('Info.plist'))).toBe(true);
    expect(changes.some((change) => change.file.includes('AndroidManifest.xml'))).toBe(true);
    expect(changes.filter((change) => change.apply)).toHaveLength(0);
  });

  it('does not require iOS setup for an Android-only Flutter host', () => {
    const pubspec = join(tmpDir, 'pubspec.yaml');
    writeFileSync(pubspec, 'name: app\n', 'utf8');
    mkdirSync(join(tmpDir, 'android'), { recursive: true });

    const changes = planChanges({
      type: 'flutter',
      paths: { pubspec },
    });

    expect(changes.some((change) => change.file.includes('Info.plist'))).toBe(false);
    expect(changes.some((change) => change.file.includes('entitlements'))).toBe(false);
    expect(changes.some((change) => change.file === 'project.pbxproj')).toBe(false);
  });

  it('AndroidManifest change is safe and idempotent', () => {
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    writeFileSync(manifestPath, MANIFEST_WITHOUT_PERM, 'utf8');

    const info: ProjectInfo = {
      type: 'react-native',
      paths: { androidManifest: manifestPath },
    };
    const changes = planChanges(info);
    const manifestChange = changes.find((c) => c.file === manifestPath);
    expect(manifestChange?.apply).toBeInstanceOf(Function);

    manifestChange!.apply!();
    expect(readFileSync(manifestPath, 'utf8')).toContain('POST_NOTIFICATIONS');

    manifestChange!.apply!();
    const after2 = readFileSync(manifestPath, 'utf8');
    expect((after2.match(/POST_NOTIFICATIONS/g) ?? []).length).toBe(1);

    const followup = planChanges(info);
    expect(followup.some((change) => change.file === manifestPath)).toBe(false);
  });
});

describe('planChanges — unknown project', () => {
  it('returns an empty change list', () => {
    const info: ProjectInfo = { type: 'unknown', paths: {} };
    expect(planChanges(info)).toHaveLength(0);
  });
});

describe('planChanges — native Android Firebase', () => {
  it('requests the client JSON before touching Gradle when it is missing', () => {
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    const projectGradle = join(tmpDir, 'build.gradle.kts');
    const appGradle = join(tmpDir, 'app.gradle.kts');
    writeFileSync(manifestPath, MANIFEST_WITHOUT_PERM, 'utf8');
    writeFileSync(projectGradle, 'plugins {\n}\n', 'utf8');
    writeFileSync(appGradle, 'plugins {\n}\n', 'utf8');

    const changes = planChanges({
      type: 'android',
      paths: {
        androidManifest: manifestPath,
        androidProjectGradle: projectGradle,
        androidAppGradle: appGradle,
      },
    });

    expect(changes.some((change) => change.file.endsWith('google-services.json'))).toBe(true);
    expect(changes.some((change) => change.file === projectGradle)).toBe(false);
    expect(changes.some((change) => change.file === appGradle)).toBe(false);
  });

  it('wires both Gradle files when a valid client JSON exists', () => {
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    const projectGradle = join(tmpDir, 'build.gradle.kts');
    const appGradle = join(tmpDir, 'app.gradle.kts');
    const googleServices = join(tmpDir, 'google-services.json');
    writeFileSync(manifestPath, MANIFEST_WITHOUT_PERM, 'utf8');
    writeFileSync(projectGradle, 'plugins {\n}\n', 'utf8');
    writeFileSync(appGradle, 'plugins {\n}\n', 'utf8');
    writeFileSync(googleServices, GOOGLE_SERVICES_JSON, 'utf8');

    const info: ProjectInfo = {
      type: 'android',
      paths: {
        androidManifest: manifestPath,
        androidProjectGradle: projectGradle,
        androidAppGradle: appGradle,
        googleServicesJson: googleServices,
      },
    };
    const changes = planChanges(info);
    for (const change of changes.filter((candidate) => candidate.apply)) change.apply!();

    expect(readFileSync(projectGradle, 'utf8')).toContain('version "4.4.2" apply false');
    expect(readFileSync(appGradle, 'utf8')).toContain('id("com.google.gms.google-services")');
    expect(planChanges(info).filter((change) => change.file.includes('gradle'))).toHaveLength(0);
  });

  it('rejects a client config for a different applicationId', () => {
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    const appGradle = join(tmpDir, 'app.gradle.kts');
    const googleServices = join(tmpDir, 'google-services.json');
    writeFileSync(manifestPath, MANIFEST_WITHOUT_PERM, 'utf8');
    writeFileSync(
      appGradle,
      'android { defaultConfig { applicationId = "com.example.correct" } }',
      'utf8',
    );
    writeFileSync(googleServices, GOOGLE_SERVICES_JSON, 'utf8');

    const changes = planChanges({
      type: 'android',
      paths: {
        androidManifest: manifestPath,
        androidAppGradle: appGradle,
        googleServicesJson: googleServices,
      },
    });
    const firebaseChange = changes.find((change) => change.file === googleServices);
    expect(firebaseChange?.apply).toBeUndefined();
    expect(firebaseChange?.manualInstructions).toContain('com.example.correct');
  });

  it('requires manual verification for a dynamic applicationId', () => {
    const manifestPath = join(tmpDir, 'AndroidManifest.xml');
    const appGradle = join(tmpDir, 'app.gradle.kts');
    const googleServices = join(tmpDir, 'google-services.json');
    writeFileSync(manifestPath, MANIFEST_WITHOUT_PERM, 'utf8');
    writeFileSync(
      appGradle,
      'android { namespace = "com.example.fallback"; applicationId = providers.gradleProperty("APP_ID").get() }',
      'utf8',
    );
    writeFileSync(googleServices, GOOGLE_SERVICES_JSON, 'utf8');

    const changes = planChanges({
      type: 'android',
      paths: {
        androidManifest: manifestPath,
        androidAppGradle: appGradle,
        googleServicesJson: googleServices,
      },
    });
    const firebaseChange = changes.find((change) => change.file === googleServices);
    expect(firebaseChange?.apply).toBeUndefined();
    expect(firebaseChange?.manualInstructions).toContain('dynamically');
  });
});
