import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { detectProject } from '../src/detect';

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

describe('detectProject', () => {
  it('returns unknown when nothing matches', () => {
    const result = detectProject(tmpDir);
    expect(result.type).toBe('unknown');
  });

  it('detects expo from app.json with an expo key', () => {
    write('app.json', JSON.stringify({ expo: { name: 'MyApp' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('expo');
    expect(result.paths.appJson).toContain('app.json');
  });

  it('detects expo from app.config.js (dynamic config)', () => {
    write('app.config.js', 'module.exports = {};');
    const result = detectProject(tmpDir);
    expect(result.type).toBe('expo');
  });

  it('does NOT treat a plain app.json without expo key as expo', () => {
    write('app.json', JSON.stringify({ name: 'other' }));
    // No package.json with react-native either → should fall through to unknown.
    const result = detectProject(tmpDir);
    expect(result.type).toBe('unknown');
  });

  it('detects flutter from pubspec.yaml', () => {
    write('pubspec.yaml', 'name: my_app\nflutter:\n');
    const result = detectProject(tmpDir);
    expect(result.type).toBe('flutter');
    expect(result.paths.pubspec).toContain('pubspec.yaml');
  });

  it('prefers expo over react-native when both markers exist', () => {
    write('app.json', JSON.stringify({ expo: { name: 'MyApp' } }));
    write('package.json', JSON.stringify({ dependencies: { 'react-native': '0.73.0' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('expo');
  });

  it('detects react-native from package.json with react-native dep', () => {
    write('package.json', JSON.stringify({ dependencies: { 'react-native': '0.73.0' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('react-native');
    expect(result.paths.packageJson).toContain('package.json');
  });

  it('detects react-native from devDependencies too', () => {
    write('package.json', JSON.stringify({ devDependencies: { 'react-native': '0.73.0' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('react-native');
  });

  it('ignores package.json without react-native', () => {
    write('package.json', JSON.stringify({ dependencies: { react: '18.0.0' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('web');
  });

  it('detects common browser frameworks as web projects', () => {
    write('package.json', JSON.stringify({ devDependencies: { vite: '7.0.0' } }));
    const result = detectProject(tmpDir);
    expect(result.type).toBe('web');
    expect(result.paths.packageJson).toContain('package.json');
  });

  it('detects the legacy web SDK during the beta migration', () => {
    write('package.json', JSON.stringify({ dependencies: { '@notifie-dev/web': '0.1.0' } }));
    expect(detectProject(tmpDir).type).toBe('web');
  });

  it('does not classify an unrelated Node package as a web app', () => {
    write('package.json', JSON.stringify({ dependencies: { express: '5.0.0' } }));
    expect(detectProject(tmpDir).type).toBe('unknown');
  });

  it('detects swift from a *.xcodeproj directory', () => {
    mkdirSync(join(tmpDir, 'MyApp.xcodeproj'), { recursive: true });
    const result = detectProject(tmpDir);
    expect(result.type).toBe('swift');
  });

  it('detects swift from Package.swift', () => {
    write('Package.swift', '// swift-tools-version: 5.9');
    const result = detectProject(tmpDir);
    expect(result.type).toBe('swift');
  });

  it('resolves Info.plist inside ios/<AppName>/', () => {
    write('app.json', JSON.stringify({ expo: {} }));
    write('ios/MyApp/Info.plist', '<plist></plist>');
    const result = detectProject(tmpDir);
    expect(result.paths.infoPlist).toContain('Info.plist');
  });

  it('resolves AndroidManifest.xml at the standard Android path', () => {
    write('pubspec.yaml', 'name: my_app');
    write('android/app/src/main/AndroidManifest.xml', '<manifest></manifest>');
    const result = detectProject(tmpDir);
    expect(result.paths.androidManifest).toContain('AndroidManifest.xml');
  });

  it('detects a native Android project and its Firebase files', () => {
    write('build.gradle.kts', 'plugins {}');
    write('app/build.gradle.kts', 'plugins { id("com.android.application") }');
    write('app/src/main/AndroidManifest.xml', '<manifest></manifest>');
    write('app/google-services.json', '{"project_info":{"project_id":"demo"}}');

    const result = detectProject(tmpDir);

    expect(result.type).toBe('android');
    expect(result.paths.androidProjectGradle).toContain('build.gradle.kts');
    expect(result.paths.androidAppGradle).toContain('app/build.gradle.kts');
    expect(result.paths.googleServicesJson).toContain('app/google-services.json');
  });

  it('records a missing google-services.json without inventing a path', () => {
    write('build.gradle', 'plugins {}');
    write('app/build.gradle', "plugins { id 'com.android.application' }");
    write('app/src/main/AndroidManifest.xml', '<manifest></manifest>');

    const result = detectProject(tmpDir);

    expect(result.type).toBe('android');
    expect(result.paths.googleServicesJson).toBeUndefined();
  });
});
