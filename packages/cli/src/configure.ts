import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import type { ProjectInfo } from './detect.ts';

export interface ProjectChange {
  /** Path to the file being changed, for display. */
  file: string;
  /** One-line description of what will change. */
  description: string;
  /**
   * Execute the change in place. Undefined for changes that are not safe to
   * automate — the caller must print `manualInstructions` instead.
   *
   * Editing project.pbxproj to add a capability is the canonical example of
   * "not safe": Xcode maintains internal object-graph consistency in that file
   * and the format is not fully documented. Getting it wrong can corrupt a
   * project in ways that require git history to recover. The developer can add
   * the capability with a single checkbox click, so it is better to ask them
   * than to risk corrupting their project silently.
   */
  apply?: () => void;
  /** Exact steps to follow when apply is absent, or supplementary context when it is present. */
  manualInstructions?: string;
}

// ---------------------------------------------------------------------------
// Pure content-transformation helpers
// These operate on strings and never touch the filesystem, so they are
// straightforward to test and to compose.
// ---------------------------------------------------------------------------

/** True if the plist already declares remote-notification in UIBackgroundModes. */
export function plistHasBackgroundMode(content: string): boolean {
  if (!isStructurallyValidPlist(content)) return false;
  const match = /<key>UIBackgroundModes<\/key>\s*<array>([\s\S]*?)<\/array>/
    .exec(stripXmlComments(content));
  if (!match) return false;
  return (match[1] ?? '').includes('<string>remote-notification</string>');
}

/**
 * Adds remote-notification to UIBackgroundModes in a plist string.
 * Creates the key if it is absent. Idempotent.
 */
export function plistAddBackgroundMode(content: string): string {
  if (plistHasBackgroundMode(content)) return content;

  // Key exists but doesn't contain remote-notification — append to the array.
  const searchable = maskXmlComments(content);
  const arrayPattern = /<key>UIBackgroundModes<\/key>\s*<array>[\s\S]*?<\/array>/;
  const arrayMatch = arrayPattern.exec(searchable);
  if (arrayMatch !== null) {
    const closeOffset = arrayMatch[0].lastIndexOf('</array>');
    const closeIndex = arrayMatch.index + closeOffset;
    const beforeClose = content.slice(arrayMatch.index, closeIndex);
    const entryIndent = (/\n(\s*)<string>/.exec(beforeClose) ?? [])[1] ?? '\t\t';
    const closeIndent = (/\n(\s*)$/.exec(beforeClose) ?? [])[1] ?? '\t';
    const insert = `${entryIndent}<string>remote-notification</string>\n${closeIndent}`;
    return content.slice(0, closeIndex) + insert + content.slice(closeIndex);
  }
  if (stripXmlComments(content).includes('<key>UIBackgroundModes</key>')) {
    return content;
  }

  // Key absent — insert before the outermost </dict>.
  const lastClose = searchable.lastIndexOf('</dict>');
  if (lastClose === -1) return content; // malformed; leave untouched
  const insert = '\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>remote-notification</string>\n\t</array>\n\t';
  return content.slice(0, lastClose) + insert + content.slice(lastClose);
}

/** True if the entitlements plist already contains aps-environment. */
export function entitlementsHasApsEnvironment(content: string): boolean {
  if (!isStructurallyValidPlist(content)) return false;
  return /<key>aps-environment<\/key>\s*<string>(development|production)<\/string>/
    .test(stripXmlComments(content));
}

/**
 * Adds aps-environment: development to an entitlements plist.
 * Idempotent.
 */
export function entitlementsAddApsEnvironment(content: string): string {
  if (entitlementsHasApsEnvironment(content)) return content;
  if (stripXmlComments(content).includes('<key>aps-environment</key>')) {
    return content;
  }

  const lastClose = maskXmlComments(content).lastIndexOf('</dict>');
  if (lastClose === -1) return content;
  const insert = '\t<key>aps-environment</key>\n\t<string>development</string>\n\t';
  return content.slice(0, lastClose) + insert + content.slice(lastClose);
}

/** True if the manifest already contains POST_NOTIFICATIONS. */
export function manifestHasNotificationPermission(content: string): boolean {
  const manifest = parseXmlRoot(content, 'manifest');
  if (!manifest || typeof manifest !== 'object') return false;
  const permissions = (manifest as Record<string, unknown>)['uses-permission'];
  const list = Array.isArray(permissions) ? permissions : [permissions];
  return list.some(
    (permission) =>
      typeof permission === 'object' &&
      permission !== null &&
      (permission as Record<string, unknown>)['@_android:name'] ===
        'android.permission.POST_NOTIFICATIONS',
  );
}

/**
 * Adds the POST_NOTIFICATIONS uses-permission to an AndroidManifest.xml string.
 * Required from API level 33 (Android 13). Idempotent.
 */
export function manifestAddNotificationPermission(content: string): string {
  if (manifestHasNotificationPermission(content)) return content;

  const newPerm = '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />';

  // Prefer inserting after the last existing uses-permission element.
  const searchable = maskXmlComments(content);
  let lastEnd = -1;
  const re = /<uses-permission[^>]*(\/\s*>|>\s*<\/uses-permission>)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(searchable)) !== null) {
    lastEnd = m.index + m[0].length;
  }

  if (lastEnd !== -1) {
    return content.slice(0, lastEnd) + '\n' + newPerm + content.slice(lastEnd);
  }

  // No existing uses-permission elements — insert just before <application.
  const appIdx = searchable.indexOf('<application');
  if (appIdx !== -1) {
    const lineStart = content.lastIndexOf('\n', appIdx - 1) + 1;
    const leading = content.slice(lineStart, appIdx);

    if (/^\s*$/.test(leading)) {
      return content.slice(0, lineStart) + newPerm + '\n' + content.slice(lineStart);
    }

    return content.slice(0, appIdx) + `\n${newPerm}\n    ` + content.slice(appIdx);
  }

  return content;
}

export interface GoogleServicesInfo {
  projectId: string;
  packages: string[];
}

/** Read the Android applicationId from common Kotlin/Groovy Gradle syntax. */
export function parseAndroidApplicationId(content: string): string | null {
  const searchable = stripGradleComments(content);
  const applicationId = /\bapplicationId\s*(?:=\s*)?["']([^"']+)["']/
    .exec(searchable);
  if (applicationId?.[1]?.trim()) return applicationId[1].trim();
  if (/\bapplicationId\b/.test(searchable)) return null;
  const namespace = /\bnamespace\s*(?:=\s*)?["']([^"']+)["']/.exec(searchable);
  return namespace?.[1]?.trim() || null;
}

export function hasUnresolvedAndroidApplicationId(content: string): boolean {
  const searchable = stripGradleComments(content);
  return /\bapplicationId\b/.test(searchable) &&
    !/\bapplicationId\s*(?:=\s*)?["'][^"']+["']/.test(searchable);
}

function stripGradleComments(content: string): string {
  let output = '';
  let quote: '"' | "'" | null = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < content.length; index += 1) {
    const char = content[index] ?? '';
    const next = content[index + 1] ?? '';
    if (lineComment) {
      if (char === '\n') {
        lineComment = false;
        output += char;
      }
      continue;
    }
    if (blockComment) {
      if (char === '*' && next === '/') {
        blockComment = false;
        index += 1;
      } else if (char === '\n') {
        output += '\n';
      }
      continue;
    }
    if (quote) {
      output += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      output += char;
    } else if (char === '/' && next === '/') {
      lineComment = true;
      index += 1;
    } else if (char === '/' && next === '*') {
      blockComment = true;
      index += 1;
    } else {
      output += char;
    }
  }
  return output;
}

/** Parse Firebase's public Android client config, rejecting service-account JSON. */
export function parseGoogleServicesJson(content: string): GoogleServicesInfo | null {
  try {
    const json = JSON.parse(content) as {
      project_info?: { project_id?: unknown };
      client?: Array<{ client_info?: { android_client_info?: { package_name?: unknown } } }>;
    };
    const projectId = json.project_info?.project_id;
    const packages = (json.client ?? [])
      .map((client) => client.client_info?.android_client_info?.package_name)
      .filter((name): name is string => typeof name === 'string' && name.length > 0);

    if (typeof projectId !== 'string' || projectId.length === 0 || packages.length === 0) {
      return null;
    }
    return { projectId, packages };
  } catch {
    return null;
  }
}

export function gradleHasGoogleServicesPlugin(
  content: string,
  target: 'project' | 'app' | 'any' = 'any',
): boolean {
  const searchable = stripGradleComments(content);
  const lines = searchable.split('\n').filter(
    (line) =>
      line.includes('com.google.gms.google-services') ||
      line.includes('com.google.gms:google-services') ||
      /libs\.plugins\.[\w.]*google[\w.]*services/i.test(line),
  );
  if (target === 'project' || target === 'any') {
    if (lines.length > 0) return true;
  }
  return lines.some((line) =>
    !/\bapply\s+false\b/.test(line) &&
    (
      /id\s*(?:\(\s*)?["']com\.google\.gms\.google-services["']/.test(line) ||
      /apply\s+plugin\s*:\s*["']com\.google\.gms\.google-services["']/.test(line) ||
      /alias\s*\([^)]*google[^)]*services/i.test(line)
    ));
}

/** Add the Google Services plugin to an existing plugins block. Idempotent. */
export function gradleAddGoogleServicesPlugin(
  content: string,
  target: 'project' | 'app',
  kotlinDsl: boolean,
): string {
  if (gradleHasGoogleServicesPlugin(content, target)) return content;

  const line = kotlinDsl
    ? target === 'project'
      ? 'id("com.google.gms.google-services") version "4.4.2" apply false'
      : 'id("com.google.gms.google-services")'
    : target === 'project'
      ? "id 'com.google.gms.google-services' version '4.4.2' apply false"
      : "id 'com.google.gms.google-services'";

  const plugins = /plugins\s*\{/.exec(content);
  if (plugins) {
    const insertAt = plugins.index + plugins[0].length;
    return `${content.slice(0, insertAt)}\n    ${line}${content.slice(insertAt)}`;
  }

  if (target === 'app' && !kotlinDsl && /apply plugin:/.test(content)) {
    return `${content.trimEnd()}\napply plugin: 'com.google.gms.google-services'\n`;
  }

  return content;
}

/** True if expo.ios.infoPlist.UIBackgroundModes contains remote-notification. */
export function expoHasBackgroundMode(appJson: Record<string, unknown>): boolean {
  const expo = appJson.expo as Record<string, unknown> | undefined;
  const ios = expo?.ios as Record<string, unknown> | undefined;
  const plist = ios?.infoPlist as Record<string, unknown> | undefined;
  const modes = plist?.UIBackgroundModes;
  return Array.isArray(modes) && (modes as unknown[]).includes('remote-notification');
}

/**
 * Returns a new app.json with all push notification settings merged in.
 * Preserves every unrelated key. Idempotent.
 */
export function expoAddPushConfig(appJson: Record<string, unknown>): Record<string, unknown> {
  // Full deep clone — we must not mutate the caller's object.
  const result = JSON.parse(JSON.stringify(appJson)) as Record<string, unknown>;

  const expo = (result.expo ?? {}) as Record<string, unknown>;
  result.expo = expo;

  // iOS: UIBackgroundModes and aps-environment entitlement
  const ios = (expo.ios ?? {}) as Record<string, unknown>;
  expo.ios = ios;

  const plist = (ios.infoPlist ?? {}) as Record<string, unknown>;
  ios.infoPlist = plist;

  const modes = Array.isArray(plist.UIBackgroundModes)
    ? (plist.UIBackgroundModes as string[]).slice()
    : [];
  if (!modes.includes('remote-notification')) modes.push('remote-notification');
  plist.UIBackgroundModes = modes;

  const entitlements = (ios.entitlements ?? {}) as Record<string, unknown>;
  ios.entitlements = entitlements;
  if (!entitlements['aps-environment']) entitlements['aps-environment'] = 'development';

  // Android: POST_NOTIFICATIONS
  const android = (expo.android ?? {}) as Record<string, unknown>;
  expo.android = android;

  const perms = Array.isArray(android.permissions)
    ? (android.permissions as string[]).slice()
    : [];
  if (!perms.includes('android.permission.POST_NOTIFICATIONS')) {
    perms.push('android.permission.POST_NOTIFICATIONS');
  }
  android.permissions = perms;

  return result;
}

// ---------------------------------------------------------------------------
// ProjectChange factories
// ---------------------------------------------------------------------------

const XCODE_CAPABILITY_INSTRUCTIONS = `In Xcode:
  1. Open your .xcodeproj
  2. Select your app target → Signing & Capabilities
  3. Click "+ Capability" and add "Push Notifications"

Notifie does not modify project.pbxproj because Xcode maintains internal
consistency data in that file that is hard to replicate from outside. Getting
it wrong can corrupt the project in ways that require git history to recover.
Adding the capability in Xcode is one checkbox and is much safer.`.trim();

function stripXmlComments(content: string): string {
  return content.replace(/<!--[\s\S]*?-->/g, '');
}

function maskXmlComments(content: string): string {
  return content.replace(/<!--[\s\S]*?-->/g, (comment) =>
    comment.replace(/[^\n]/g, ' '));
}

function parseXmlRoot(content: string, expectedRoot: string): unknown | null {
  if (XMLValidator.validate(content) !== true) return null;
  const parsed = new XMLParser({
    ignoreAttributes: false,
    allowBooleanAttributes: true,
  }).parse(content) as Record<string, unknown>;
  const roots = Object.keys(parsed).filter((key) => !key.startsWith('?'));
  return roots.length === 1 && roots[0] === expectedRoot
    ? parsed[expectedRoot] ?? null
    : null;
}

export function isStructurallyValidPlist(content: string): boolean {
  const plist = parseXmlRoot(content, 'plist');
  if (plist && typeof plist === 'object') {
    return Object.hasOwn(plist, 'dict');
  }
  return parseXmlRoot(content, 'dict') !== null;
}

export function isStructurallyValidAndroidManifest(content: string): boolean {
  const manifest = parseXmlRoot(content, 'manifest');
  return typeof manifest === 'object' &&
    manifest !== null &&
    Object.hasOwn(manifest, 'application');
}

function makeInfoPlistChange(plistPath: string): ProjectChange {
  const current = readFileSync(plistPath, 'utf8');
  if (
    !isStructurallyValidPlist(current) ||
    (plistAddBackgroundMode(current) === current && !plistHasBackgroundMode(current))
  ) {
    return {
      file: plistPath,
      description: 'Repair Info.plist before adding remote-notification',
      manualInstructions:
        'The file is malformed or does not contain a plist <dict>. Repair it in Xcode, then rerun `notifie init`.',
    };
  }
  return {
    file: plistPath,
    description: 'Add remote-notification to UIBackgroundModes',
    apply() {
      const current = readFileSync(plistPath, 'utf8');
      writeFileSync(plistPath, plistAddBackgroundMode(current), 'utf8');
    },
  };
}

function makeEntitlementsChange(entitlementsPath: string): ProjectChange {
  const current = readFileSync(entitlementsPath, 'utf8');
  if (
    !isStructurallyValidPlist(current) ||
    (
      entitlementsAddApsEnvironment(current) === current &&
      !entitlementsHasApsEnvironment(current)
    )
  ) {
    return {
      file: entitlementsPath,
      description: 'Repair entitlements before adding aps-environment',
      manualInstructions:
        'The file is malformed or does not contain a plist <dict>. Repair it in Xcode, then rerun `notifie init`.',
    };
  }
  return {
    file: entitlementsPath,
    description: 'Add aps-environment: development',
    apply() {
      const current = readFileSync(entitlementsPath, 'utf8');
      writeFileSync(entitlementsPath, entitlementsAddApsEnvironment(current), 'utf8');
    },
  };
}

function makeAndroidManifestChange(manifestPath: string): ProjectChange {
  const current = readFileSync(manifestPath, 'utf8');
  if (!isStructurallyValidAndroidManifest(current)) {
    return {
      file: manifestPath,
      description: 'Repair AndroidManifest.xml before adding POST_NOTIFICATIONS',
      manualInstructions:
        'The file is malformed or has no <manifest>/<application> structure. Repair it, then rerun `notifie init`.',
    };
  }

  return {
    file: manifestPath,
    description: 'Add POST_NOTIFICATIONS uses-permission (required from API 33)',
    apply() {
      const current = readFileSync(manifestPath, 'utf8');
      writeFileSync(manifestPath, manifestAddNotificationPermission(current), 'utf8');
    },
  };
}

function appendAndroidManifestChange(manifestPath: string, changes: ProjectChange[]): void {
  const current = readFileSync(manifestPath, 'utf8');
  if (!manifestHasNotificationPermission(current)) {
    changes.push(makeAndroidManifestChange(manifestPath));
  }
}

function firebaseJsonTarget(info: ProjectInfo): string {
  if (info.paths.androidAppGradle) {
    return join(dirname(info.paths.androidAppGradle), 'google-services.json');
  }
  return info.type === 'android' ? 'app/google-services.json' : 'android/app/google-services.json';
}

function makeGradlePluginChange(
  filePath: string,
  target: 'project' | 'app',
): ProjectChange | null {
  const current = readFileSync(filePath, 'utf8');
  if (gradleHasGoogleServicesPlugin(current, target)) return null;

  const kotlinDsl = filePath.endsWith('.kts');
  const updated = gradleAddGoogleServicesPlugin(current, target, kotlinDsl);
  if (updated === current) {
    return {
      file: filePath,
      description: `Apply com.google.gms.google-services to the Android ${target}`,
      manualInstructions:
        `No plugins block was found. Apply com.google.gms.google-services in this ${target} Gradle file, then rerun notifie doctor.`,
    };
  }

  return {
    file: filePath,
    description: target === 'project'
      ? 'Declare the Google Services Gradle plugin'
      : 'Apply the Google Services Gradle plugin to the app module',
    apply() {
      const latest = readFileSync(filePath, 'utf8');
      writeFileSync(
        filePath,
        gradleAddGoogleServicesPlugin(latest, target, kotlinDsl),
        'utf8',
      );
    },
  };
}

function appendAndroidFirebaseChanges(info: ProjectInfo, changes: ProjectChange[]): void {
  const jsonPath = info.paths.googleServicesJson;
  const expectedPath = firebaseJsonTarget(info);

  if (!jsonPath) {
    changes.push({
      file: expectedPath,
      description: 'Add the Firebase Android client configuration',
      manualInstructions: [
        'Firebase Console → Project settings → General → Your apps → Add Android app.',
        'Use the applicationId from the app module Gradle file.',
        `Download google-services.json and place it at ${expectedPath}.`,
        'Then rerun `notifie init YOUR_SDK_INGEST_KEY --yes` to finish Gradle wiring.',
      ].join('\n'),
    });
    return;
  }

  const googleServices = parseGoogleServicesJson(readFileSync(jsonPath, 'utf8'));
  if (!googleServices) {
    changes.push({
      file: jsonPath,
      description: 'Replace the invalid Firebase Android client configuration',
      manualInstructions:
        'This is not a valid google-services.json. Download the Android app config from\n' +
        'Firebase Console → Project settings → General. Do not use a service-account key here.',
    });
    return;
  }

  const appGradle = info.paths.androidAppGradle
    ? readFileSync(info.paths.androidAppGradle, 'utf8')
    : null;
  const applicationId = appGradle ? parseAndroidApplicationId(appGradle) : null;
  if (appGradle && hasUnresolvedAndroidApplicationId(appGradle)) {
    changes.push({
      file: jsonPath,
      description: 'Verify Firebase config against the dynamic applicationId',
      manualInstructions:
        'The app computes applicationId dynamically, so Notifie cannot verify google-services.json safely.\n' +
        'Confirm the resolved applicationId matches a package in this Firebase config, then rerun `notifie doctor`.',
    });
    return;
  }
  if (applicationId && !googleServices.packages.includes(applicationId)) {
    changes.push({
      file: jsonPath,
      description: 'Replace Firebase config for the Android applicationId',
      manualInstructions:
        `google-services.json contains ${googleServices.packages.join(', ')}, but the app uses ${applicationId}.\n` +
        'Download the matching Android app config from Firebase Console, then rerun `notifie init`.',
    });
    return;
  }

  if (info.paths.androidProjectGradle) {
    const projectChange = makeGradlePluginChange(info.paths.androidProjectGradle, 'project');
    if (projectChange) changes.push(projectChange);
  }
  if (info.paths.androidAppGradle) {
    const appChange = makeGradlePluginChange(info.paths.androidAppGradle, 'app');
    if (appChange) changes.push(appChange);
  }
}

function makeXcodeCapabilityChange(): ProjectChange {
  return {
    file: 'project.pbxproj',
    description: 'Enable Push Notifications capability',
    // No apply — see XCODE_CAPABILITY_INSTRUCTIONS for why.
    manualInstructions: XCODE_CAPABILITY_INSTRUCTIONS,
  };
}

function makeExpoAppJsonChange(appJsonPath: string): ProjectChange {
  return {
    file: appJsonPath,
    description: 'Merge push notification config (UIBackgroundModes, aps-environment, POST_NOTIFICATIONS)',
    apply() {
      const current = JSON.parse(readFileSync(appJsonPath, 'utf8')) as Record<string, unknown>;
      writeFileSync(appJsonPath, `${JSON.stringify(expoAddPushConfig(current), null, 2)}\n`, 'utf8');
    },
  };
}

/**
 * Return the ordered list of changes needed to enable push for this project.
 *
 * Changes with `apply` are safe to write programmatically.
 * Changes without `apply` must be performed manually; `manualInstructions`
 * gives the exact steps.
 */
export function planChanges(info: ProjectInfo): ProjectChange[] {
  const changes: ProjectChange[] = [];
  const rootMarker = info.paths.pubspec ?? info.paths.packageJson ?? info.paths.appJson;
  const projectRoot = rootMarker ? dirname(rootMarker) : null;
  const hasIosDirectory = projectRoot ? existsSync(join(projectRoot, 'ios')) : false;
  const hasAndroidDirectory = projectRoot ? existsSync(join(projectRoot, 'android')) : false;

  switch (info.type) {
    case 'expo':
      if (info.paths.appJson) {
        changes.push(makeExpoAppJsonChange(info.paths.appJson));
      } else {
        // app.config.js was detected but we can't safely eval it to add keys.
        changes.push({
          file: 'app.config.js',
          description: 'Add push notification config',
          manualInstructions: [
            'In app.config.js, add to the ios section:',
            "  infoPlist: { UIBackgroundModes: ['remote-notification'] },",
            "  entitlements: { 'aps-environment': 'development' }",
            'And to the android section:',
            "  permissions: ['android.permission.POST_NOTIFICATIONS']",
          ].join('\n'),
        });
      }
      if (info.paths.infoPlist || info.paths.entitlements) {
        changes.push(makeXcodeCapabilityChange());
      }
      break;

    case 'flutter':
    case 'react-native':
      if (info.paths.infoPlist) {
        changes.push(makeInfoPlistChange(info.paths.infoPlist));
      } else if (hasIosDirectory) {
        changes.push({
          file: 'ios/**/Info.plist',
          description: 'Restore the iOS Info.plist',
          manualInstructions:
            'An ios directory exists, but no Info.plist was found. Restore or regenerate the iOS host, then rerun `notifie init`.',
        });
      }
      if (info.paths.entitlements) {
        changes.push(makeEntitlementsChange(info.paths.entitlements));
      } else if (hasIosDirectory) {
        changes.push({
          file: '*.entitlements',
          description: 'Create entitlements file with aps-environment',
          manualInstructions:
            'No entitlements file found. Add the Push Notifications capability in Xcode\n' +
            '(Target → Signing & Capabilities) — Xcode creates the file automatically.',
        });
      }
      if (info.paths.androidManifest) {
        appendAndroidManifestChange(info.paths.androidManifest, changes);
      } else if (hasAndroidDirectory) {
        changes.push({
          file: 'android/app/src/main/AndroidManifest.xml',
          description: 'Restore the Android manifest',
          manualInstructions:
            'An android directory exists, but AndroidManifest.xml was not found. Restore or regenerate the Android host, then rerun `notifie init`.',
        });
      }
      if (hasIosDirectory || info.paths.infoPlist || info.paths.entitlements) {
        changes.push(makeXcodeCapabilityChange());
      }
      break;

    case 'android':
      if (info.paths.androidManifest) {
        appendAndroidManifestChange(info.paths.androidManifest, changes);
      }
      break;

    case 'swift':
      // Raw Swift/Xcode projects: Info.plist is not at a predictable path from
      // outside the .xcodeproj, and touching project.pbxproj is never safe.
      changes.push({
        file: 'Info.plist',
        description: 'Add remote-notification to UIBackgroundModes',
        manualInstructions:
          'Open Info.plist in Xcode and add:\n' +
          '  Key:   UIBackgroundModes\n' +
          '  Type:  Array\n' +
          '  Value: remote-notification',
      });
      changes.push({
        file: '*.entitlements',
        description: 'Add aps-environment: development',
        manualInstructions:
          'Target → Signing & Capabilities → Push Notifications.\n' +
          'Xcode creates the entitlements file with aps-environment automatically.',
      });
      changes.push(makeXcodeCapabilityChange());
      break;

    case 'web':
    case 'unknown':
      break;
  }

  if (info.paths.androidManifest) {
    appendAndroidFirebaseChanges(info, changes);
  }

  return changes;
}
