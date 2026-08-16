#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import readline from 'node:readline/promises';
import { parseApiKey } from '@notifie/contracts';
import {
  NOTIFIE_TEMPLATE_CATALOG,
  findTemplateMetadata,
} from '@notifie/contracts/templates';
import {
  DEFAULT_BASE_URL,
  checkApiKey,
  checkAuthenticationStatus,
  checkReachable,
  checkProjectDetected,
  checkSdkPresent,
  checkFlutterSdkPresent,
  checkMissingHostFile,
  checkIosBackgroundMode,
  checkIosEntitlement,
  checkAndroidPermission,
  checkGoogleServicesJson,
  checkGoogleServicesGradle,
  androidApplicationId,
  androidApplicationIdIsDynamic,
  checkDeviceTokens,
  checkPushCredentialsUploaded,
  checkEventsFlowing,
  formatResults,
  summarise,
  type CheckResult,
  type DoctorConfig,
} from './doctor.ts';
import { detectProject } from './detect.ts';
import { planChanges } from './configure.ts';
import { resolveGoogleServicesCheckpoint } from './firebase-setup.ts';

/**
 * The Notifie CLI.
 *
 * Config lives in a plain `notifie.json` next to the project rather than in a
 * hidden global location, so it is obvious, reviewable and per-project.
 */

const CONFIG_FILE = 'notifie.json';
const LEGACY_CONFIG_FILE = 'notifie.json';

interface LoadedConfig {
  config: DoctorConfig;
  error?: string;
}

function loadConfig(cwd = process.cwd()): LoadedConfig {
  const currentPath = resolve(cwd, CONFIG_FILE);
  const legacyPath = resolve(cwd, LEGACY_CONFIG_FILE);
  const path = existsSync(currentPath) ? currentPath : legacyPath;
  const fileName = path === currentPath ? CONFIG_FILE : LEGACY_CONFIG_FILE;

  const fromEnv: DoctorConfig = {
    apiKey: process.env.NOTIFIE_API_KEY ?? process.env.NOTIFIE_API_KEY,
    baseUrl: process.env.NOTIFIE_URL ?? process.env.NOTIFIE_URL,
  };

  if (!existsSync(path)) return { config: fromEnv };

  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as unknown;
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return { config: fromEnv, error: `${fileName} must contain a JSON object.` };
    }
    const record = parsed as Record<string, unknown>;
    if (
      (record.apiKey !== undefined && typeof record.apiKey !== 'string') ||
      (record.baseUrl !== undefined && typeof record.baseUrl !== 'string')
    ) {
      return {
        config: fromEnv,
        error: `${fileName} apiKey and baseUrl must be strings.`,
      };
    }
    // Environment wins, so CI can override without editing a file.
    return {
      config: {
        apiKey: fromEnv.apiKey ?? record.apiKey as string | undefined,
        baseUrl: fromEnv.baseUrl ?? record.baseUrl as string | undefined,
      },
    };
  } catch {
    return { config: fromEnv, error: `${fileName} is not valid JSON.` };
  }
}

function saveConfig(config: DoctorConfig, cwd = process.cwd()): void {
  writeFileSync(resolve(cwd, CONFIG_FILE), `${JSON.stringify(config, null, 2)}\n`);
}

function print(message = ''): void {
  process.stdout.write(`${message}\n`);
}

async function cmdInit(args: string[]): Promise<number> {
  const unknownFlags = args.filter((arg) => arg.startsWith('-') && arg !== '--yes');
  const positionals = args.filter((arg) => !arg.startsWith('-'));
  if (unknownFlags.length > 0 || positionals.length > 1) {
    print(`\n  ✗ Unknown or extra argument: ${unknownFlags[0] ?? positionals[1]}`);
    print('    Usage: notifie init YOUR_SDK_INGEST_KEY [--yes]\n');
    return 1;
  }
  const yes = args.includes('--yes');
  const apiKey = positionals[0];

  if (!apiKey) {
    print('\n  Usage: notifie init YOUR_SDK_INGEST_KEY [--yes]\n');
    print('  Find your key in the Notifie dashboard under API Keys.\n');
    return 1;
  }

  if (!parseApiKey(apiKey)) {
    print('\n  ✗ That does not look like a Notifie key.');
    print('    Keys look like ntf_live_<lookup>_<secret> (legacy gk_ keys remain valid).\n');
    return 1;
  }

  let info = detectProject();
  if (info.type === 'unknown') {
    print('\n  ✗ No supported app was detected in this directory.');
    print(`    Current directory: ${process.cwd()}\n`);
    print('  Run notifie init from an existing app root containing one of:');
    print('    • iOS: an .xcodeproj or Package.swift');
    print('    • Android: app/build.gradle(.kts) and AndroidManifest.xml');
    print('    • Flutter: pubspec.yaml');
    print('    • React Native / Expo / Web: package.json or app.json\n');
    print('  No files were changed. Create an app first or cd into its root, then retry.\n');
    return 1;
  }

  const baseUrl = process.env.NOTIFIE_URL ?? process.env.NOTIFIE_URL ?? DEFAULT_BASE_URL;
  saveConfig({ apiKey, baseUrl });
  print(`\n  ✓ Wrote ${CONFIG_FILE}`);

  print(`\n  Project type: ${info.type}`);

  const changes = planChanges(info);
  if (changes.length > 0) {
    print('\n  Planned changes:\n');
    for (const change of changes) {
      const marker = change.apply !== undefined ? '●' : '○';
      print(`    ${marker} ${change.file}`);
      print(`      ${change.description}`);
      if (change.apply === undefined) print('      (manual — see steps below)');
    }

    const safeChanges = changes.filter((c) => c.apply !== undefined);
    let manualChanges = changes.filter((c) => c.apply === undefined);

    let shouldApply = yes;
    if (!shouldApply && process.stdin.isTTY) {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      try {
        const answer = await rl.question('\n  Apply safe changes? [y/N] ');
        shouldApply = answer.trim().toLowerCase() === 'y';
      } finally {
        rl.close();
      }
    }

    if (shouldApply && safeChanges.length > 0) {
      print('\n  Applying safe changes...');
      for (const change of safeChanges) {
        change.apply!();
        print(`    ✓ ${change.file}`);
      }
    } else if (!shouldApply && safeChanges.length > 0) {
      print('\n  Skipped file writes. Re-run with --yes to apply automatically.');
    }

    const firebaseChange = manualChanges.find((change) =>
      change.file.endsWith('google-services.json'),
    );
    if (firebaseChange) {
      let rl: readline.Interface | null = null;
      if (process.stdin.isTTY) {
        rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      }

      let checkpoint: Awaited<ReturnType<typeof resolveGoogleServicesCheckpoint>>;
      try {
        checkpoint = await resolveGoogleServicesCheckpoint(firebaseChange.file, {
          interactive: rl !== null,
          ask: (question) => rl?.question(question) ?? Promise.resolve('s'),
          print,
        });
      } finally {
        rl?.close();
      }

      if (checkpoint === 'ready') {
        info = detectProject();
        const followup = planChanges(info);
        const alreadyApplied = new Set(safeChanges.map((change) => change.file));
        const newlySafe = followup.filter(
          (change) => change.apply !== undefined && !alreadyApplied.has(change.file),
        );

        if (newlySafe.length > 0) {
          print('\n  Firebase unlocked additional safe changes:\n');
          for (const change of newlySafe) {
            print(`    ● ${change.file}`);
            print(`      ${change.description}`);
          }

          if (shouldApply) {
            print('\n  Applying Firebase changes...');
            for (const change of newlySafe) {
              change.apply!();
              print(`    ✓ ${change.file}`);
            }
          } else {
            print('\n  Re-run with --yes to apply the Firebase Gradle changes.');
          }
        }

        manualChanges = followup.filter((change) => change.apply === undefined);
      } else if (checkpoint === 'skipped') {
        manualChanges = manualChanges.filter((change) => change !== firebaseChange);
      }
    }

    if (manualChanges.length > 0) {
      print('\n  Manual steps required:\n');
      for (const change of manualChanges) {
        print(`  ■ ${change.file}: ${change.description}`);
        if (change.manualInstructions) {
          for (const line of change.manualInstructions.split('\n')) {
            print(`    ${line}`);
          }
        }
        print();
      }
    }
  }

  const hasAndroid = Boolean(info.paths.androidManifest) || info.type === 'android';
  const hasIos = ['expo', 'react-native', 'flutter', 'swift'].includes(info.type);

  if (hasAndroid) {
    print('  Firebase sender credential\n');
    print('    Upload the private service-account JSON in Notifie: Integration → Push Providers.');
    print('    Keep it out of the Android app. The CLI only reads public google-services.json.');
    print(`    Dashboard: ${baseUrl}\n`);
  }

  if (hasIos) {
    // Apple scopes .p8 keys to the developer's team account, so this remains manual.
    print('  APNs credentials\n');
    print('    Upload your .p8 file in Notifie: Integration → Push Providers.');
    print('    This cannot be automated: Apple ties APNs keys to your developer team.');
    print(`    Dashboard: ${baseUrl}\n`);
  }

  print('  Add to your app:\n');
  switch (info.type) {
    case 'android':
      print('    import dev.notifie.Notifie');
      print(`    Notifie.initialize(applicationContext, "${apiKey.slice(0, 16)}…")`);
      print('    Notifie.enableNotifications()\n');
      break;
    case 'flutter':
      print(`    await Notifie.initialize(apiKey: '${apiKey.slice(0, 16)}…');`);
      print('    await Notifie.enableNotifications();\n');
      break;
    case 'expo':
    case 'react-native':
      print(`    await Notifie.initialize({ apiKey: '${apiKey.slice(0, 16)}…' });`);
      print('    await Notifie.enableNotifications();\n');
      break;
    case 'swift':
      print('    import Notifie');
      print(`    Growth.initialize(apiKey: "${apiKey.slice(0, 16)}…")`);
      print('    Growth.enableNotifications()\n');
      break;
    case 'web':
      print(`    Notifie.initialize({ apiKey: '${apiKey.slice(0, 16)}…' });`);
      print("    await Notifie.track('app_open');\n");
      break;
    case 'unknown':
      print('    Follow the platform guide in Integration.\n');
      break;
  }

  print('  Then run `notifie doctor`.\n');
  return 0;
}

async function cmdDoctor(): Promise<number> {
  const loaded = loadConfig();
  const config = loaded.config;
  print('\n  Notifie doctor\n');

  const results: CheckResult[] = [];
  if (loaded.error) {
    results.push({
      name: 'Project config',
      status: 'fail',
      message: loaded.error,
      fix: 'Repair or delete notifie.json (or legacy notifie.json), then rerun `notifie init`.',
    });
  }

  const info = detectProject();
  results.push(checkProjectDetected(info.type));

  if (info.paths.packageJson) {
    try {
      const pkg = JSON.parse(readFileSync(info.paths.packageJson, 'utf8')) as {
        dependencies?: Record<string, unknown>;
        devDependencies?: Record<string, unknown>;
      };
      const deps = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) };
      results.push(checkSdkPresent(deps));
    } catch {
      results.push({
        name: 'SDK dependency',
        status: 'fail',
        message: 'package.json is malformed or could not be read.',
        fix: 'Repair package.json and ensure the Notifie SDK is listed in dependencies.',
      });
    }
  }

  if (info.paths.pubspec) {
    try {
      results.push(checkFlutterSdkPresent(readFileSync(info.paths.pubspec, 'utf8')));
    } catch {
      results.push({
        name: 'SDK dependency',
        status: 'fail',
        message: 'pubspec.yaml could not be read.',
        fix: 'Repair pubspec.yaml, then rerun `notifie doctor`.',
      });
    }
  }

  if (
    ['flutter', 'react-native'].includes(info.type) &&
    existsSync(resolve(process.cwd(), 'ios'))
  ) {
    if (!info.paths.infoPlist) results.push(checkMissingHostFile('Info.plist'));
    if (!info.paths.entitlements) results.push(checkMissingHostFile('entitlements'));
  }

  if (info.paths.infoPlist) {
    try {
      results.push(checkIosBackgroundMode(readFileSync(info.paths.infoPlist, 'utf8')));
    } catch {
      results.push({
        name: 'iOS background mode',
        status: 'fail',
        message: 'Info.plist could not be read.',
        fix: 'Fix the file permissions or restore Info.plist, then rerun `notifie doctor`.',
      });
    }
  }

  if (info.paths.entitlements) {
    try {
      results.push(checkIosEntitlement(readFileSync(info.paths.entitlements, 'utf8')));
    } catch {
      results.push({
        name: 'iOS entitlement',
        status: 'fail',
        message: 'The entitlements file could not be read.',
        fix: 'Fix the file permissions or restore the file, then rerun `notifie doctor`.',
      });
    }
  }

  if (info.paths.androidManifest) {
    try {
      results.push(checkAndroidPermission(readFileSync(info.paths.androidManifest, 'utf8')));
    } catch {
      results.push({
        name: 'Android permission',
        status: 'fail',
        message: 'AndroidManifest.xml could not be read.',
        fix: 'Fix the file permissions or restore the manifest, then rerun `notifie doctor`.',
      });
    }

    let projectGradleContent: string | null = null;
    let appGradleContent: string | null = null;
    try {
      if (info.paths.androidProjectGradle) {
        projectGradleContent = readFileSync(info.paths.androidProjectGradle, 'utf8');
      }
      if (info.paths.androidAppGradle) {
        appGradleContent = readFileSync(info.paths.androidAppGradle, 'utf8');
      }
    } catch {
      // Missing content produces an actionable failed check.
    }
    let googleServicesContent: string | null = null;
    if (info.paths.googleServicesJson) {
      try {
        googleServicesContent = readFileSync(info.paths.googleServicesJson, 'utf8');
      } catch {
        // Reported as missing/unreadable below.
      }
    }
    results.push(
      checkGoogleServicesJson(
        googleServicesContent,
        androidApplicationId(appGradleContent),
        androidApplicationIdIsDynamic(appGradleContent),
      ),
    );
    results.push(checkGoogleServicesGradle(projectGradleContent, appGradleContent));
  } else if (
    ['flutter', 'react-native', 'expo'].includes(info.type) &&
    existsSync(resolve(process.cwd(), 'android'))
  ) {
    results.push(checkMissingHostFile('AndroidManifest.xml'));
  }

  const requiredProviders: Array<'apns' | 'fcm'> = [];
  if (info.type === 'android' || info.paths.androidManifest) requiredProviders.push('fcm');
  if (info.type === 'swift' || info.paths.infoPlist || info.paths.entitlements) {
    requiredProviders.push('apns');
  }
  if (info.type === 'expo') {
    let platforms = ['ios', 'android'];
    if (info.paths.appJson) {
      try {
        const appJson = JSON.parse(readFileSync(info.paths.appJson, 'utf8')) as {
          expo?: { platforms?: unknown };
        };
        if (
          Array.isArray(appJson.expo?.platforms) &&
          appJson.expo.platforms.every((platform) => typeof platform === 'string')
        ) {
          platforms = appJson.expo.platforms;
        }
      } catch {
        // Malformed app.json is already reported through project detection.
      }
    }
    if (platforms.includes('ios') && !requiredProviders.includes('apns')) {
      requiredProviders.push('apns');
    }
    if (platforms.includes('android') && !requiredProviders.includes('fcm')) {
      requiredProviders.push('fcm');
    }
  }
  results.push(...(await runChecks(config, info.type, requiredProviders)));

  print(formatResults(results));
  print();

  return summarise(results).ok ? 0 : 1;
}

/**
 * The checks that depend only on the server, split out from the command so
 * tests and the onboarding harness can assert on individual results rather
 * than on an exit code.
 */
export async function runChecks(
  config: DoctorConfig,
  projectType?: ReturnType<typeof detectProject>['type'],
  requiredProviders: Array<'apns' | 'fcm'> = [],
): Promise<CheckResult[]> {
  const authentication = await checkAuthenticationStatus(config, { fetch });
  const results: CheckResult[] = [
    checkApiKey(config),
    await checkReachable(config, { fetch }),
    authentication.check,
  ];

  const status = authentication.status;
  results.push(checkEventsFlowing(status));
  if (projectType !== 'web') {
    results.push(checkPushCredentialsUploaded(status, requiredProviders));
    results.push(checkDeviceTokens(status));
  }
  return results;
}

function cmdTemplates(): number {
  print('\n  Notifie templates\n');

  const byCategory = new Map<string, typeof NOTIFIE_TEMPLATE_CATALOG>();
  for (const template of NOTIFIE_TEMPLATE_CATALOG) {
    const list = byCategory.get(template.category) ?? [];
    list.push(template);
    byCategory.set(template.category, list);
  }

  for (const [category, list] of byCategory) {
    print(`  ${category}`);
    for (const template of list) {
      print(`    ${template.id.padEnd(26)} ${template.summary}`);
    }
    print();
  }

  print('  Install one with: notifie install <id>\n');
  return 0;
}

function cmdInstall(args: string[]): number {
  const id = args[0];

  if (!id) {
    print('\n  Usage: notifie install <template-id>');
    print('  Run `notifie templates` to see the options.\n');
    return 1;
  }

  const template = findTemplateMetadata(id);
  if (!template) {
    print(`\n  ✗ No template called "${id}".`);
    print('    Run `notifie templates` to see what exists.\n');
    return 1;
  }

  // Installing binds a template to an app, and the CLI has an API key rather
  // than a dashboard session. Rather than inventing a second auth path, point
  // at the place where the decision (which trigger event to bind) can actually
  // be shown.
  print(`\n  ${template.name}`);
  print(`  ${template.description}\n`);
  print('  Install it from the dashboard so you can confirm which of your');
  print('  events it binds to:\n');
  print(`    ${loadConfig().config.baseUrl ?? DEFAULT_BASE_URL}\n`);
  return 0;
}

async function cmdTestPush(): Promise<number> {
  const loaded = loadConfig();
  if (loaded.error) {
    print(`\n  ✗ ${loaded.error}`);
    print('    Repair or delete notifie.json (or legacy notifie.json), then rerun `notifie init`.\n');
    return 1;
  }
  const config = loaded.config;

  if (!config.apiKey) {
    print('\n  ✗ No API key configured. Run `notifie init YOUR_SDK_INGEST_KEY` first.\n');
    return 1;
  }

  const baseUrl = config.baseUrl ?? DEFAULT_BASE_URL;
  const userId = `cli-test-${Date.now()}`;

  try {
    const response = await fetch(`${baseUrl}/api/v1/events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.apiKey}` },
      body: JSON.stringify({
        events: [{ userId, event: 'app_open', properties: { source: 'notifie test-push' } }],
      }),
    });

    if (!response.ok) {
      print(`\n  ✗ The server rejected the test event (${response.status}).`);
      print('    Run `notifie doctor` to find out why.\n');
      return 1;
    }

    const receipt = await response.json().catch(() => null) as Record<string, unknown> | null;
    if (
      !receipt ||
      receipt.received !== 1 ||
      typeof receipt.inserted !== 'number' ||
      typeof receipt.duplicates !== 'number' ||
      !Number.isInteger(receipt.inserted) ||
      !Number.isInteger(receipt.duplicates) ||
      receipt.inserted < 0 ||
      receipt.duplicates < 0 ||
      receipt.inserted + receipt.duplicates !== receipt.received
    ) {
      print('\n  ✗ The server returned an unexpected success response.');
      print('    Check NOTIFIE_URL; it must point to a compatible Notifie server.\n');
      return 1;
    }

    print(`\n  ✓ Sent a test app_open event as ${userId}.`);
    print('    It should appear in your live stream within a second.\n');
    return 0;
  } catch {
    print(`\n  ✗ Could not reach ${baseUrl}.\n`);
    return 1;
  }
}

function usage(): number {
  print('\n  notifie — Notifie CLI\n');
  print('    notifie init YOUR_SDK_INGEST_KEY     Save the key and configure the detected project');
  print('    notifie doctor             Check your setup end to end');
  print('    notifie templates          List available notifie templates');
  print('    notifie install <id>       Show what a template does');
  print('    notifie test-push          Send a test event\n');
  return 0;
}

export async function run(argv: string[]): Promise<number> {
  const [command, ...args] = argv;
  if (
    command !== 'init' &&
    command !== 'install' &&
    command !== undefined &&
    command !== '-h' &&
    command !== '--help' &&
    args.length > 0
  ) {
    print(`\n  ✗ Command "${command}" does not accept arguments.`);
    return 1;
  }
  if (command === 'install' && args.length > 1) {
    print('\n  ✗ `notifie install` accepts exactly one template ID.');
    print('    Usage: notifie install <template-id>\n');
    return 1;
  }

  switch (command) {
    case 'init':
      return cmdInit(args);
    case 'doctor':
      return cmdDoctor();
    case 'templates':
      return cmdTemplates();
    case 'install':
      return cmdInstall(args);
    case 'test-push':
      return cmdTestPush();
    case undefined:
    case '-h':
    case '--help':
      return usage();
    default:
      print(`\n  Unknown command "${command}".`);
      return usage() || 1;
  }
}

// Only run when invoked directly, so tests can import `run` freely.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop() ?? '')) {
  run(process.argv.slice(2)).then((code) => process.exit(code));
}
