# Working in this repository

Read [CONTRIBUTING.md](../CONTRIBUTING.md) for setup and expectations, and
[RELEASING.md](../RELEASING.md) before touching a version. The rules below exist
because each one has already cost real time here.

## Start from current main

Fetch before you read, review or change anything:

```bash
git fetch origin && git log --oneline -1 origin/main
```

If the branch is behind, merge main in first. A review of stale code produces
confident findings about bugs that were fixed weeks ago, and there is no signal
that this has happened -- the code looks wrong because it *was* wrong.

Before reporting something as broken, confirm it is still broken on current
main. Two of the defects reported in one session had already been fixed there.

## A fix is delivered when it is published, not when it is merged

Every registry here treats a version as immutable, and publishing is manual for
everything except npm. So merging is the midpoint, not the end:

1. Bump the version in the same change as the fix.
2. Merge.
3. Publish to the registry (see RELEASING.md).

A merged fix that was never published reaches nobody, while the repository reads
as though it shipped. Run the guard before opening a pull request:

```bash
.github/scripts/check-version-bumps.sh origin/main
```

CI runs it too, and the weekly drift check stays red until the version in the
tree exists on its registry. That red is the intent, not a fault.

## main is the only integration point

Branch from main, open a pull request into main, and take other people's work by
merging main in.

**Never move commits between branches** with cherry-pick or a cross-branch
rebase. Doing that produces two commits with identical content and different
hashes, which then look merged from one branch and missing from another, and
conflict when both land. This has already happened here.

## One agent session per area at a time

Two sessions editing the same files in this repository have already produced
duplicated commits and a working tree that silently reverted a merged release
bump. If work must run in parallel, split it so the file sets cannot overlap,
and never run two sessions against the same SDK.

If a merge commit, or a modified file, appears that you did not create: stop and
inspect it before committing. It may be another session's work, or a stale tree
about to revert something already released.

## Verify with the native toolchain

`pnpm check` does not cover the native SDKs. A change under `sdks/android`,
`sdks/swift` or `sdks/flutter` is unverified until its own toolchain has run:

```bash
cd sdks/android && ./gradlew :notifie:testDebugUnitTest
xcrun swift test --package-path sdks/swift
cd sdks/flutter && flutter analyze && flutter test
cd examples/flutter/android && ./gradlew :notifie_flutter:testDebugUnitTest
```

The Swift package builds for macOS by default, so `swift test` compiles none of
the UIKit paths. Build for a real iOS target when changing them.

Add the regression test with the fix, and confirm it fails without the fix.
A test that passes either way documents nothing.
