#!/usr/bin/env bash
#
# Reports every fix that is merged but not published.
#
# This project's SDKs are released by hand: .github/workflows/publish.yml
# automates npm only, so Android, Flutter and Swift reach users solely because
# somebody remembered. A forgotten publish leaves no trace -- main looks
# healthy, CI is green, the fix is in the tree, and users keep hitting a bug
# that reads as fixed. This turns that silence into a failing scheduled run.
#
# Failing is the point. It stays red until the version in the tree exists on the
# registry, which is the only evidence that a user can actually install it.
#
# Run locally:
#
#   .github/scripts/check-release-drift.sh
#
set -euo pipefail

# shellcheck source=.github/scripts/lib-versions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-versions.sh"

# name | manifest | registry | coordinate
#
# packages/server, sdks/react-native and sdks/web are deliberately absent: the
# README lists them as source-available with a reserved coordinate, so they are
# unpublished on purpose. Including them would make this permanently red, and a
# check that is always red is a check nobody reads.
TARGETS=(
  "Android|sdks/android/notifie/build.gradle.kts|maven|dev/notifie/notifie-android"
  "Swift|Notifie.podspec|cocoapods|Notifie"
  "Flutter|sdks/flutter/pubspec.yaml|pub|notifie_flutter"
  "Contracts|packages/contracts/package.json|npm|@notifie-dev/contracts"
  "CLI|packages/cli/package.json|npm|@notifie-dev/cli"
)

# Lists the versions a registry has published, or exits non-zero when the
# registry could not be reached at all.
#
# The distinction matters more than it looks: a blocked or flaky lookup that
# silently returned "no versions" would report every SDK as unpublished and
# train everyone to ignore this report.
fetch_published() {
  local registry="$1" coordinate="$2" url response body code

  case "$registry" in
    maven)
      url="https://repo1.maven.org/maven2/${coordinate}/maven-metadata.xml"
      ;;
    pub)
      url="https://pub.dev/api/packages/${coordinate}"
      ;;
    cocoapods)
      url="https://trunk.cocoapods.org/api/v1/pods/${coordinate}"
      ;;
    npm)
      # A scoped name has to be percent-encoded or the registry reads the slash
      # as a path separator and answers 404 for a package that exists.
      url="https://registry.npmjs.org/${coordinate//\//%2F}"
      ;;
    *)
      return 1
      ;;
  esac

  response="$(curl -sS --max-time 30 -w $'\n%{http_code}' "$url" 2>/dev/null)" || return 1
  code="$(tail -n1 <<<"$response")"
  body="$(sed '$d' <<<"$response")"

  # 404 is a real answer: the coordinate has never been published.
  [ "$code" = "404" ] && return 0
  [ "$code" = "200" ] || return 1

  case "$registry" in
    maven)
      sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' <<<"$body"
      ;;
    pub)
      node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);(j.versions||[]).forEach(v=>console.log(v.version))})' <<<"$body"
      ;;
    cocoapods)
      node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);(j.versions||[]).forEach(v=>console.log(v.name))})' <<<"$body"
      ;;
    npm)
      node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);Object.keys(j.versions||{}).forEach(v=>console.log(v))})' <<<"$body"
      ;;
  esac
}

drift=0
unknown=0
report=""

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name manifest registry coordinate <<<"$entry"

  local_version="$(version_in_file "$manifest")"
  if [ -z "$local_version" ]; then
    report+="| $name | unreadable | - | manifest unparsed |"$'\n'
    unknown=$((unknown + 1))
    continue
  fi

  if ! published="$(fetch_published "$registry" "$coordinate")"; then
    report+="| $name | $local_version | not checked | registry unreachable |"$'\n'
    unknown=$((unknown + 1))
    echo "warning: could not reach $registry for $coordinate; skipping" >&2
    continue
  fi

  latest="$(tail -n1 <<<"$published")"
  # Asking whether this exact version is published, rather than comparing
  # order, sidesteps prerelease semver entirely: "0.1.0-beta.5" either exists
  # on the registry or it does not.
  if grep -Fxq "$local_version" <<<"$published"; then
    report+="| $name | $local_version | $local_version | published |"$'\n'
  else
    drift=$((drift + 1))
    report+="| $name | $local_version | ${latest:-none} | **NOT PUBLISHED** |"$'\n'
  fi
done

summary="## Release drift

| SDK | In repo | On registry | State |
| --- | --- | --- | --- |
$report"

echo "$summary"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$summary" >>"$GITHUB_STEP_SUMMARY"

if [ "$unknown" -gt 0 ]; then
  echo ""
  echo "$unknown registry lookup(s) could not be completed. Those rows prove nothing."
fi

if [ "$drift" -gt 0 ]; then
  cat <<EOF

$drift SDK(s) carry a version in the tree that no registry serves.

Until each is published, the fixes it contains have not reached a single user.
Publishing is manual for Android, Flutter and Swift -- publish.yml covers npm
only -- so this will stay red until somebody runs the release.
EOF
  exit 1
fi

echo ""
echo "Every published SDK matches the version in the tree."
