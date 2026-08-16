import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { resolveGoogleServicesCheckpoint } from '../src/firebase-setup.ts';

const VALID_GOOGLE_SERVICES = JSON.stringify({
  project_info: { project_id: 'notifie-test' },
  client: [{
    client_info: {
      android_client_info: { package_name: 'com.example.app' },
    },
  }],
});

describe('resolveGoogleServicesCheckpoint', () => {
  let tmpDir = '';
  let filePath = '';

  beforeEach(() => {
    tmpDir = mkdtempSync(join(import.meta.dirname, '..', 'firebase-setup-'));
    filePath = join(tmpDir, 'google-services.json');
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it('never prompts in a non-interactive process', async () => {
    let asked = false;
    const result = await resolveGoogleServicesCheckpoint(filePath, {
      interactive: false,
      ask: async () => {
        asked = true;
        return 'y';
      },
      print: () => undefined,
    });

    expect(result).toBe('unavailable');
    expect(asked).toBe(false);
  });

  it('shows help, waits, and continues once a valid file appears', async () => {
    const output: string[] = [];
    let questions = 0;
    const result = await resolveGoogleServicesCheckpoint(filePath, {
      interactive: true,
      ask: async () => {
        questions += 1;
        if (questions === 1) return 'h';
        writeFileSync(filePath, VALID_GOOGLE_SERVICES, 'utf8');
        return 'yes';
      },
      print: (message = '') => output.push(message),
    });

    expect(result).toBe('ready');
    expect(output.join('\n')).toContain('No Firebase project yet');
    expect(output.join('\n')).toContain('Continuing setup');
  });

  it('rejects a service-account key and allows the user to replace it', async () => {
    writeFileSync(filePath, JSON.stringify({
      type: 'service_account',
      project_id: 'notifie-test',
      private_key: 'secret',
    }), 'utf8');

    const output: string[] = [];
    let questions = 0;
    const result = await resolveGoogleServicesCheckpoint(filePath, {
      interactive: true,
      ask: async () => {
        questions += 1;
        if (questions === 1) return 'y';
        writeFileSync(filePath, VALID_GOOGLE_SERVICES, 'utf8');
        return 'y';
      },
      print: (message = '') => output.push(message),
    });

    expect(result).toBe('ready');
    expect(output.join('\n')).toContain('not a valid Firebase Android client config');
  });

  it('lets the user skip without waiting forever', async () => {
    const result = await resolveGoogleServicesCheckpoint(filePath, {
      interactive: true,
      ask: async () => 'skip',
      print: () => undefined,
    });

    expect(result).toBe('skipped');
  });
});