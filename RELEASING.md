# Releasing

Read this before publishing anything. Two properties make releases here
unforgiving, and neither is obvious from the repository:

**A published version can never be replaced.** Maven Central, pub.dev,
CocoaPods and npm all refuse to overwrite one. A mistake is not corrected, it is
superseded by another version, and the broken one stays installable forever.

**Publishing is manual for three of the four registries.**
`.github/workflows/publish.yml` automates npm only. Android, Flutter and Swift
reach users solely because somebody ran the steps below. Nothing fails when that
is skipped: `main` looks healthy, CI is green, the fix is in the tree, and users
keep hitting a bug that reads as fixed.

## What CI checks, and what it cannot

Two checks exist because two different things go wrong.

`.github/scripts/check-version-bumps.sh` runs on every pull request and fails
one that edits shipping source without bumping the version it ships under. It
reads only source directories, so tests, examples and build configuration do not
trigger it. A change that genuinely ships nothing can carry the
`no-version-bump` label.

`.github/scripts/check-release-drift.sh` runs weekly and fails while a version
in the tree is missing from the registry that serves it. This is the check that
notices a forgotten publish. **It stays red until you publish** — that is the
design, not a fault. A registry that cannot be reached is reported as
`not checked` rather than as drift, so a network failure never masquerades as an
unpublished release.

Neither check can publish for you. They only make the gap visible.

Run either locally:

```bash
.github/scripts/check-version-bumps.sh origin/main
.github/scripts/check-release-drift.sh
```

## Order matters

The Flutter plugin depends on the published Android artifact, not on the source
beside it:

```
sdks/flutter/android/build.gradle
  implementation "dev.notifie:notifie-android:<version>"
```

So an Android fix reaches Flutter users only after the Android artifact is on
Maven Central and the pin is moved. Releasing Flutter first ships a version that
still carries the old Android code, and the pin makes that invisible.

```
Android  ->  Maven Central
             then bump the pin and the Flutter version
Flutter  ->  pub.dev
```

Swift and the npm packages are independent and can be released in any order.

## Android to Maven Central

The build stages a bundle locally rather than uploading directly, so the exact
bytes can be inspected before they become permanent.

1. Bump `notifieVersion` in `sdks/android/notifie/build.gradle.kts`.
2. Build the signed bundle. Signing material is read from the environment so it
   is never written into the repository:

   ```bash
   cd sdks/android
   NOTIFIE_SIGNING_KEY="$(cat /path/to/private-key.asc)" \
   NOTIFIE_SIGNING_PASSWORD='...' \
     ./gradlew :notifie:centralBundle
   ```

3. **Verify it is signed.** Signing is skipped silently when the key is absent,
   so an unsigned bundle builds successfully and is rejected only at upload:

   ```bash
   unzip -l notifie/build/central-portal/*.zip | grep -c '\.asc$'   # must be > 0
   ```

4. Upload `sdks/android/notifie/build/central-portal/notifie-android-<version>-bundle.zip`
   at <https://central.sonatype.com/publishing>, under *Publish Component*.
5. Wait for it to appear, then confirm:

   ```bash
   curl -s https://repo1.maven.org/maven2/dev/notifie/notifie-android/maven-metadata.xml | grep '<version>'
   ```

6. Update the version in the README table and the install snippet, and remove
   the entry for it under *Known issues in published versions*.

## Flutter to pub.dev

No artifact to upload; `pub` publishes from the working tree.

1. Move the Android pin in `sdks/flutter/android/build.gradle` to the version
   you just published. Do not do this before it is live on Maven Central, or
   the build cannot resolve it.
2. Bump `version` in `sdks/flutter/pubspec.yaml` and add a `CHANGELOG.md` entry.
   The changelog is what a developer reads before upgrading, so say what broke
   and what now happens instead, not just that something was fixed.
3. Verify before publishing:

   ```bash
   cd sdks/flutter
   flutter analyze && flutter test
   flutter pub publish --dry-run
   ```

4. Publish:

   ```bash
   flutter pub publish
   ```

5. Update the README table and install snippet.

## Swift to CocoaPods

1. Bump `spec.version` in `Notifie.podspec`.
2. Tag the commit as `swift-<version>`; the podspec resolves its source from
   that tag, so the tag must exist and point at the released code:

   ```bash
   git tag swift-0.1.0-beta.N && git push origin swift-0.1.0-beta.N
   ```

3. Verify, then push:

   ```bash
   pod spec lint Notifie.podspec
   pod trunk push Notifie.podspec
   ```

## npm packages

Automated, and the only registry that is. Actions -> **Publish** ->
*Run workflow*.

The defaults are deliberately safe: `dry_run` is true and the target is `cli`.
Run it once with `dry_run` enabled to see exactly what would be uploaded, then
again with it disabled. The workflow refuses to publish a prerelease under the
`latest` tag, because that is what a plain `npm install` resolves to.

## After any release

Run the drift check. It is the only thing that confirms a user can actually
install what you just published:

```bash
.github/scripts/check-release-drift.sh
```

## Credentials

Never commit signing material. The Android signing key is read from
`NOTIFIE_SIGNING_KEY` and `NOTIFIE_SIGNING_PASSWORD`, pub.dev and CocoaPods
authenticate through their own CLI login, and the npm token lives in Actions
secrets. The credential-scan job in CI rejects a commit containing a `.p8`,
`.p12`, keystore, service account or `.env` file, but it cannot catch a secret
pasted into source, so keep them out of the tree.
