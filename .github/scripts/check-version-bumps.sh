#!/usr/bin/env bash
#
# Fails a change that edits shipping code without bumping the version it ships
# under.
#
# A published version is immutable everywhere this project releases: Maven
# Central, pub.dev, CocoaPods and npm all refuse to replace one. So a fix merged
# without a bump is not "released later", it is unreleasable -- the artifact
# users install still carries the old code, and the only way out is another
# commit. That failure is invisible at review time, because the diff looks
# complete and every test passes.
#
# Run locally the same way CI does:
#
#   .github/scripts/check-version-bumps.sh origin/main
#
set -euo pipefail

BASE_REF="${1:-origin/main}"

# shellcheck source=.github/scripts/lib-versions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-versions.sh"

# Each entry is: name | version file | shipping paths (space separated)
#
# Only source directories are listed. Tests, examples and build configuration
# are deliberately excluded: they change behaviour for contributors, not for
# the artifact a user installs, and a guard that fires on them would be muted
# within a week.
SDKS=(
  "Android|sdks/android/notifie/build.gradle.kts|sdks/android/notifie/src/main/"
  "Swift|Notifie.podspec|sdks/swift/Sources/"
  "Flutter|sdks/flutter/pubspec.yaml|sdks/flutter/lib/ sdks/flutter/android/src/main/ sdks/flutter/ios/Classes/"
  "Contracts|packages/contracts/package.json|packages/contracts/src/"
  "CLI|packages/cli/package.json|packages/cli/src/"
  "Server|packages/server/package.json|packages/server/src/"
  "React Native|sdks/react-native/package.json|sdks/react-native/src/"
  "Web|sdks/web/package.json|sdks/web/src/"
)

# Reads the shipped version out of a manifest. Defined in lib-versions.sh and
# shared with the drift report, so the two cannot disagree about what version a
# package claims to be.
version_at() {
  local ref="$1" file="$2"
  git show "$ref:$file" 2>/dev/null || true
}

if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  echo "::error::Cannot resolve base ref '$BASE_REF'. Fetch it first (actions/checkout needs fetch-depth: 0)."
  exit 1
fi

CHANGED="$(git diff --name-only "$BASE_REF...HEAD")"
if [ -z "$CHANGED" ]; then
  echo "No changes against $BASE_REF."
  exit 0
fi

violations=0

for entry in "${SDKS[@]}"; do
  IFS='|' read -r name version_file paths <<<"$entry"

  touched=""
  for path in $paths; do
    match="$(grep -E "^${path}" <<<"$CHANGED" || true)"
    [ -n "$match" ] && touched+="$match"$'\n'
  done
  [ -z "$touched" ] && continue

  base_version="$(extract_version "$version_file" "$(version_at "$BASE_REF" "$version_file")")"
  head_version="$(extract_version "$version_file" "$(cat "$version_file" 2>/dev/null || true)")"

  if [ -z "$head_version" ]; then
    echo "::error::Could not read a version from $version_file. The guard cannot verify $name."
    violations=$((violations + 1))
    continue
  fi

  if [ "$base_version" = "$head_version" ]; then
    violations=$((violations + 1))
    echo "::error file=$version_file::$name ships changed code but is still version $head_version. Bump it in $version_file, or the fix cannot reach users."
    echo ""
    echo "  $name: shipping code changed, version unchanged ($head_version)"
    while IFS= read -r file; do
      [ -n "$file" ] && echo "      $file"
    done <<<"$touched"
    echo "      -> bump the version in $version_file"
    echo ""
  else
    echo "  $name: $base_version -> $head_version"
  fi
done

if [ "$violations" -gt 0 ]; then
  cat <<'EOF'

Every registry this project publishes to treats a version as immutable, so
shipping code that changes without a version bump can never reach a user.

If this change genuinely ships nothing -- a comment, a rename with no
behavioural effect -- add the "no-version-bump" label to the pull request.
EOF
  exit 1
fi

echo "Version bumps are consistent with the shipping code that changed."
