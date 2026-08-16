import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { run, runChecks } from '../src/main.ts';

const VALID_KEY = `ntf_live_abcdef123456_${'a'.repeat(40)}`;

describe('notifie init project-root behavior', () => {
  let originalCwd = '';
  let tmpDir = '';
  let output = '';

  beforeEach(() => {
    originalCwd = process.cwd();
    tmpDir = mkdtempSync(join(import.meta.dirname, '..', 'main-test-'));
    process.chdir(tmpDir);
    output = '';
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
      output += String(chunk);
      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    process.chdir(originalCwd);
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it('rejects an empty directory without writing notifie.json', async () => {
    const code = await run(['init', VALID_KEY, '--yes']);

    expect(code).toBe(1);
    expect(existsSync(join(tmpDir, 'notifie.json'))).toBe(false);
    expect(output).toContain('No supported app was detected');
    expect(output).toContain('No files were changed');
  });

  it('continues when run from a detected Android app root', async () => {
    const appDir = join(tmpDir, 'app');
    mkdirSync(join(appDir, 'src', 'main'), { recursive: true });
    writeFileSync(join(tmpDir, 'build.gradle.kts'), 'plugins {}\n', 'utf8');
    writeFileSync(join(appDir, 'build.gradle.kts'), 'plugins {}\n', 'utf8');
    writeFileSync(
      join(appDir, 'src', 'main', 'AndroidManifest.xml'),
      '<manifest><application /></manifest>',
      'utf8',
    );

    const code = await run(['init', VALID_KEY, '--yes']);

    expect(code).toBe(0);
    expect(existsSync(join(tmpDir, 'notifie.json'))).toBe(true);
    expect(output).toContain('Project type: android');
  });

  it('reports malformed config types instead of crashing', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: 123, baseUrl: { invalid: true } }),
      'utf8',
    );

    const code = await run(['test-push']);

    expect(code).toBe(1);
    expect(output).toContain('apiKey and baseUrl must be strings');
    expect(output).not.toContain('TypeError');
  });

  it('reads a legacy notifie.json during the beta migration', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: VALID_KEY, baseUrl: 'https://notifie.example' }),
      'utf8',
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify({
        received: 1,
        inserted: 1,
        duplicates: 0,
      }), {
        status: 202,
        headers: { 'Content-Type': 'application/json' },
      })),
    );

    expect(await run(['test-push'])).toBe(0);
    expect(output).toContain('Sent a test');
  });

  it('rejects typoed flags before writing configuration', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { vite: '^7.0.0' } }),
      'utf8',
    );

    const code = await run(['init', VALID_KEY, '--ye']);

    expect(code).toBe(1);
    expect(output).toContain('Unknown or extra argument');
    expect(existsSync(join(tmpDir, 'notifie.json'))).toBe(false);
  });

  it('rejects extra arguments for commands that take none', async () => {
    const code = await run(['doctor', 'extra']);

    expect(code).toBe(1);
    expect(output).toContain('does not accept arguments');
  });

  it('does not report test-push success for an unrelated HTTP 200', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({
        apiKey: VALID_KEY,
        baseUrl: 'https://unrelated.example',
      }),
      'utf8',
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('<html>ok</html>', { status: 200 })),
    );

    const code = await run(['test-push']);

    expect(code).toBe(1);
    expect(output).toContain('unexpected success response');
    expect(output).not.toContain('Sent a test');
  });

  it('rejects a test-push receipt that did not insert or deduplicate the event', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: VALID_KEY, baseUrl: 'https://notifie.example' }),
      'utf8',
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify({
        received: 1,
        inserted: 0,
        duplicates: 0,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })),
    );

    const code = await run(['test-push']);

    expect(code).toBe(1);
    expect(output).toContain('unexpected success response');
  });

  it('rejects fractional test-push receipt counters', async () => {
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: VALID_KEY, baseUrl: 'https://notifie.example' }),
      'utf8',
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify({
        received: 1,
        inserted: 0.5,
        duplicates: 0.5,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })),
    );

    expect(await run(['test-push'])).toBe(1);
    expect(output).toContain('unexpected success response');
  });

  it('requires both providers for a managed Expo app by default', async () => {
    writeFileSync(
      join(tmpDir, 'app.json'),
      JSON.stringify({ expo: { name: 'App', slug: 'app' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/react-native': '0.1.0' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: VALID_KEY, baseUrl: 'https://notifie.example' }),
      'utf8',
    );
    const status = {
      events: 1,
      deviceTokens: 1,
      pushCredentials: ['apns'],
      activeAutomations: 0,
      eventNames: ['app_open'],
    };
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = String(input);
        if (url.endsWith('/api/v1/events') && init?.method === 'POST') {
          return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          });
        }
        return new Response(JSON.stringify(status), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }),
    );

    const code = await run(['doctor']);

    expect(code).toBe(1);
    expect(output).toContain('Missing fcm credentials');
  });

  it('merges Expo defaults with a detected Android native host', async () => {
    writeFileSync(
      join(tmpDir, 'app.json'),
      JSON.stringify({ expo: { name: 'App', slug: 'app' } }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'package.json'),
      JSON.stringify({ dependencies: { '@notifie-dev/react-native': '0.1.0' } }),
      'utf8',
    );
    const androidApp = join(tmpDir, 'android', 'app');
    mkdirSync(join(androidApp, 'src', 'main'), { recursive: true });
    writeFileSync(
      join(androidApp, 'src', 'main', 'AndroidManifest.xml'),
      '<manifest><uses-permission android:name="android.permission.POST_NOTIFICATIONS" /><application /></manifest>',
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'android', 'build.gradle.kts'),
      'plugins { id("com.google.gms.google-services") version "4.4.2" apply false }',
      'utf8',
    );
    writeFileSync(
      join(androidApp, 'build.gradle.kts'),
      'plugins { id("com.google.gms.google-services") }\nandroid { namespace = "com.example.app" }',
      'utf8',
    );
    writeFileSync(
      join(androidApp, 'google-services.json'),
      JSON.stringify({
        project_info: { project_id: 'p' },
        client: [{
          client_info: {
            android_client_info: { package_name: 'com.example.app' },
          },
        }],
      }),
      'utf8',
    );
    writeFileSync(
      join(tmpDir, 'notifie.json'),
      JSON.stringify({ apiKey: VALID_KEY, baseUrl: 'https://notifie.example' }),
      'utf8',
    );
    const status = {
      events: 1,
      deviceTokens: 1,
      pushCredentials: ['fcm'],
      activeAutomations: 0,
      eventNames: ['app_open'],
    };
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string | URL | Request) => {
        if (String(input).endsWith('/api/v1/events')) {
          return new Response('{}', { status: 401 });
        }
        return new Response(JSON.stringify(status), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }),
    );

    expect(await run(['doctor'])).toBe(1);
    expect(output).toContain('Missing apns credentials');
  });

  it('reuses the authenticated status response instead of fetching twice', async () => {
    let statusCalls = 0;
    const status = {
      events: 1,
      deviceTokens: 0,
      pushCredentials: [],
      activeAutomations: 0,
      eventNames: ['app_open'],
    };
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string | URL | Request) => {
        if (String(input).endsWith('/api/v1/events')) {
          return new Response('{}', { status: 401 });
        }
        statusCalls += 1;
        return statusCalls === 1
          ? new Response(JSON.stringify(status), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          : new Response('{}', { status: 500 });
      }),
    );

    const results = await runChecks(
      { apiKey: VALID_KEY, baseUrl: 'https://notifie.example' },
      'web',
    );

    expect(statusCalls).toBe(1);
    expect(results.find((result) => result.name === 'Events arriving')?.status)
      .toBe('pass');
  });

  it('reports detected native files that cannot be read', async () => {
    writeFileSync(
      join(tmpDir, 'pubspec.yaml'),
      'name: app\ndependencies:\n  notifie_flutter: ^0.1.0\n',
      'utf8',
    );
    mkdirSync(join(tmpDir, 'ios', 'App', 'Info.plist'), { recursive: true });
    mkdirSync(join(tmpDir, 'ios', 'App', 'Broken.entitlements'), {
      recursive: true,
    });
    mkdirSync(
      join(tmpDir, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
      { recursive: true },
    );
    writeFileSync(
      join(tmpDir, 'android', 'app', 'build.gradle.kts'),
      'plugins {}\n',
      'utf8',
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('{}', { status: 401 })),
    );

    expect(await run(['doctor'])).toBe(1);
    expect(output).toContain('Info.plist could not be read');
    expect(output).toContain('entitlements file could not be read');
    expect(output).toContain('AndroidManifest.xml could not be read');
  });

  it('fails SDK validation when package.json is malformed', async () => {
    writeFileSync(join(tmpDir, 'app.json'), JSON.stringify({
      expo: { name: 'App', slug: 'app' },
    }), 'utf8');
    writeFileSync(join(tmpDir, 'package.json'), '{broken', 'utf8');
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('{}', { status: 401 })),
    );

    expect(await run(['doctor'])).toBe(1);
    expect(output).toContain('package.json is malformed');
  });
});