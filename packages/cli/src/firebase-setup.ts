import { existsSync, readFileSync } from 'node:fs';
import { parseGoogleServicesJson } from './configure.ts';

export type FirebaseCheckpointResult = 'ready' | 'skipped' | 'unavailable';

export interface FirebaseCheckpointDeps {
  interactive: boolean;
  ask(question: string): Promise<string>;
  print(message?: string): void;
}

function validClientConfig(filePath: string): boolean {
  if (!existsSync(filePath)) return false;
  try {
    return parseGoogleServicesJson(readFileSync(filePath, 'utf8')) !== null;
  } catch {
    return false;
  }
}

function printFirebaseHelp(filePath: string, print: FirebaseCheckpointDeps['print']): void {
  print('\n  How to get google-services.json\n');
  print('    Already have a Firebase project:');
  print('      1. Open https://console.firebase.google.com/');
  print('      2. Project settings → General → Your apps');
  print('      3. Add or select the Android app with this project\'s applicationId');
  print('      4. Download google-services.json');
  print(`      5. Save it at ${filePath}\n`);
  print('    No Firebase project yet:');
  print('      1. Open https://console.firebase.google.com/ and choose Add project');
  print('      2. Add an Android app using the applicationId from the app Gradle file');
  print(`      3. Download the file to ${filePath}\n`);
  print('    Prefer Firebase CLI:');
  print('      npm install --global firebase-tools');
  print('      firebase login');
  print('      firebase projects:list\n');
  print('    Never place a service-account private key in the Android app.');
}

export async function resolveGoogleServicesCheckpoint(
  filePath: string,
  deps: FirebaseCheckpointDeps,
): Promise<FirebaseCheckpointResult> {
  if (validClientConfig(filePath)) return 'ready';
  if (!deps.interactive) return 'unavailable';

  deps.print('\n  Firebase Android app configuration\n');
  deps.print(`    Waiting for: ${filePath}`);
  deps.print('    Notifie will continue automatically after a valid file is present.');

  while (true) {
    const answer = (await deps.ask(
      '\n  Added google-services.json? [y] yes  [h] help  [s] skip: ',
    )).trim().toLowerCase();

    if (answer === 's' || answer === 'skip') {
      deps.print('\n  Skipped Firebase app configuration for now.');
      return 'skipped';
    }

    if (answer === 'h' || answer === 'help' || answer === '?') {
      printFirebaseHelp(filePath, deps.print);
      continue;
    }

    if (answer === 'y' || answer === 'yes' || answer === '') {
      if (!existsSync(filePath)) {
        deps.print(`\n  ✗ File not found at ${filePath}`);
        deps.print('    Add it there, choose help, or skip for now.');
        continue;
      }
      if (!validClientConfig(filePath)) {
        deps.print('\n  ✗ That file is not a valid Firebase Android client config.');
        deps.print('    Download google-services.json from Project settings → General.');
        deps.print('    Do not use a service-account JSON here.');
        continue;
      }

      deps.print('\n  ✓ Found a valid google-services.json. Continuing setup...');
      return 'ready';
    }

    deps.print('\n  Choose y to re-check, h for help, or s to skip.');
  }
}