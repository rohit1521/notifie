import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

export type ProjectType = 'expo' | 'react-native' | 'flutter' | 'android' | 'swift' | 'web' | 'unknown';

export interface ProjectPaths {
  /** iOS Info.plist location, if found. */
  infoPlist?: string;
  /** iOS entitlements file, if found. */
  entitlements?: string;
  /** Android AndroidManifest.xml, if found. */
  androidManifest?: string;
  /** Android app-module build.gradle or build.gradle.kts, if found. */
  androidAppGradle?: string;
  /** Android project build.gradle or build.gradle.kts, if found. */
  androidProjectGradle?: string;
  /** Firebase Android client config, if found in the app module. */
  googleServicesJson?: string;
  /** Flutter pubspec.yaml, if found. */
  pubspec?: string;
  /** Expo app.json, if found. */
  appJson?: string;
  /** package.json, if found. */
  packageJson?: string;
  /** Native iOS application delegate, if found. */
  appDelegate?: string;
}

export interface ProjectInfo {
  type: ProjectType;
  paths: ProjectPaths;
}

function tryReadJson(filePath: string): Record<string, unknown> | null {
  try {
    const raw = JSON.parse(readFileSync(filePath, 'utf8')) as unknown;
    if (typeof raw === 'object' && raw !== null && !Array.isArray(raw)) {
      return raw as Record<string, unknown>;
    }
    return null;
  } catch {
    return null;
  }
}

/** Scan one directory level for a file ending with the given suffix. */
function findBySuffix(dir: string, suffix: string): string | undefined {
  try {
    const entries = readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.endsWith(suffix)) {
        return join(dir, entry.name);
      }
    }
  } catch {
    // dir does not exist or is not readable
  }
  return undefined;
}

/**
 * Find Info.plist in a React Native / Expo project.
 * The typical structure is ios/<AppName>/Info.plist.
 */
function findInfoPlist(cwd: string): string | undefined {
  const iosDir = join(cwd, 'ios');
  if (!existsSync(iosDir)) return undefined;

  try {
    const entries = readdirSync(iosDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        const candidate = join(iosDir, entry.name, 'Info.plist');
        if (existsSync(candidate)) return candidate;
      }
    }
  } catch {
    // ignore
  }

  const flat = join(iosDir, 'Info.plist');
  return existsSync(flat) ? flat : undefined;
}

/** Find *.entitlements in ios/ or ios/<AppName>/. */
function findEntitlements(cwd: string): string | undefined {
  const iosDir = join(cwd, 'ios');
  if (!existsSync(iosDir)) return undefined;

  try {
    const entries = readdirSync(iosDir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.endsWith('.entitlements')) return join(iosDir, entry.name);
      if (entry.isDirectory()) {
        const found = findBySuffix(join(iosDir, entry.name), '.entitlements');
        if (found) return found;
      }
    }
  } catch {
    // ignore
  }

  return undefined;
}

/** Find AndroidManifest.xml at its standard location. */
function findAndroidManifest(cwd: string): string | undefined {
  const candidates = [
    join(cwd, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    join(cwd, 'app', 'src', 'main', 'AndroidManifest.xml'),
    join(cwd, 'android', 'AndroidManifest.xml'),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return undefined;
}

function findFirst(candidates: string[]): string | undefined {
  return candidates.find((candidate) => existsSync(candidate));
}

function findAppDelegate(dir: string, depth = 0): string | undefined {
  if (depth > 4) return undefined;
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isFile() && ['AppDelegate.swift', 'AppDelegate.m', 'AppDelegate.mm'].includes(entry.name)) {
        return join(dir, entry.name);
      }
      if (
        entry.isDirectory() &&
        !['.build', '.git', 'build', 'DerivedData', 'Pods'].includes(entry.name)
      ) {
        const found = findAppDelegate(join(dir, entry.name), depth + 1);
        if (found) return found;
      }
    }
  } catch {
    // unreadable directory
  }
  return undefined;
}

function findAndroidPaths(cwd: string): Pick<
  ProjectPaths,
  'androidManifest' | 'androidAppGradle' | 'androidProjectGradle' | 'googleServicesJson'
> {
  return {
    androidManifest: findAndroidManifest(cwd),
    androidAppGradle: findFirst([
      join(cwd, 'android', 'app', 'build.gradle.kts'),
      join(cwd, 'android', 'app', 'build.gradle'),
      join(cwd, 'app', 'build.gradle.kts'),
      join(cwd, 'app', 'build.gradle'),
    ]),
    androidProjectGradle: findFirst([
      join(cwd, 'android', 'build.gradle.kts'),
      join(cwd, 'android', 'build.gradle'),
      join(cwd, 'build.gradle.kts'),
      join(cwd, 'build.gradle'),
    ]),
    googleServicesJson: findFirst([
      join(cwd, 'android', 'app', 'google-services.json'),
      join(cwd, 'app', 'google-services.json'),
    ]),
  };
}

/**
 * Detect the project type from files on disk.
 *
 * Detection order matters: Expo has a package.json too, so the Expo check
 * (app.json with an `expo` key, or app.config.js) must run before the React
 * Native check.
 */
export function detectProject(cwd = process.cwd()): ProjectInfo {
  const pkgPath = join(cwd, 'package.json');
  const appJsonPath = join(cwd, 'app.json');
  const appConfigJsPath = join(cwd, 'app.config.js');
  const pubspecPath = join(cwd, 'pubspec.yaml');

  // Expo: app.json with an `expo` key
  if (existsSync(appJsonPath)) {
    const json = tryReadJson(appJsonPath);
    if (json !== null && 'expo' in json) {
      return {
        type: 'expo',
        paths: {
          appJson: appJsonPath,
          packageJson: existsSync(pkgPath) ? pkgPath : undefined,
          infoPlist: findInfoPlist(cwd),
          entitlements: findEntitlements(cwd),
          ...findAndroidPaths(cwd),
        },
      };
    }
  }

  // Expo: app.config.js (dynamic config — we can't eval it, but its presence
  // is a strong enough signal)
  if (existsSync(appConfigJsPath)) {
    return {
      type: 'expo',
      paths: {
        packageJson: existsSync(pkgPath) ? pkgPath : undefined,
        infoPlist: findInfoPlist(cwd),
        entitlements: findEntitlements(cwd),
        ...findAndroidPaths(cwd),
      },
    };
  }

  // Flutter: pubspec.yaml
  if (existsSync(pubspecPath)) {
    return {
      type: 'flutter',
      paths: {
        pubspec: pubspecPath,
        infoPlist: findInfoPlist(cwd),
        entitlements: findEntitlements(cwd),
        ...findAndroidPaths(cwd),
      },
    };
  }

  // React Native: package.json with react-native dep (Expo already handled)
  if (existsSync(pkgPath)) {
    const pkg = tryReadJson(pkgPath);
    if (pkg !== null) {
      const deps = {
        ...((pkg.dependencies as Record<string, unknown>) ?? {}),
        ...((pkg.devDependencies as Record<string, unknown>) ?? {}),
      };
      if ('react-native' in deps) {
        return {
          type: 'react-native',
          paths: {
            packageJson: pkgPath,
            infoPlist: findInfoPlist(cwd),
            entitlements: findEntitlements(cwd),
            ...findAndroidPaths(cwd),
          },
        };
      }
    }
  }

  // Native Android: app module + manifest without Flutter/RN markers.
  const androidPaths = findAndroidPaths(cwd);
  if (androidPaths.androidManifest && androidPaths.androidAppGradle) {
    return { type: 'android', paths: androidPaths };
  }

  // Swift / iOS: *.xcodeproj or Package.swift
  if (findBySuffix(cwd, '.xcodeproj') !== undefined || existsSync(join(cwd, 'Package.swift'))) {
    return {
      type: 'swift',
      // Info.plist location is not predictable from outside the Xcode project.
      paths: { appDelegate: findAppDelegate(cwd) },
    };
  }

  // Browser app: common web framework/runtime dependency. Keep this after
  // Expo and React Native because both frequently depend on React too.
  if (existsSync(pkgPath)) {
    const pkg = tryReadJson(pkgPath);
    if (pkg !== null) {
      const deps = {
        ...((pkg.dependencies as Record<string, unknown>) ?? {}),
        ...((pkg.devDependencies as Record<string, unknown>) ?? {}),
      };
      const webMarkers = [
        '@angular/core', '@notifie-dev/web', '@notifie-dev/web', 'astro', 'next', 'nuxt', 'react',
        'svelte', 'vite', 'vue',
      ];
      if (webMarkers.some((marker) => marker in deps)) {
        return { type: 'web', paths: { packageJson: pkgPath } };
      }
    }
  }

  return { type: 'unknown', paths: {} };
}
