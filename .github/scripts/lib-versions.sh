#!/usr/bin/env bash
#
# Reads the shipped version out of a manifest, whichever dialect it is written
# in.
#
# Shared by the version-bump guard and the release-drift report so the two can
# never disagree about what version a package claims to be. If they disagreed,
# one of them would be quietly wrong and nobody would know which.

extract_version() {
  local file="$1" content="$2"
  case "$file" in
    *build.gradle.kts)
      sed -n 's/.*val notifieVersion = "\([^"]*\)".*/\1/p' <<<"$content" | head -1
      ;;
    *.podspec)
      sed -n "s/.*spec.version *= *'\([^']*\)'.*/\1/p" <<<"$content" | head -1
      ;;
    *pubspec.yaml)
      sed -n 's/^version: *\(.*\)$/\1/p' <<<"$content" | head -1
      ;;
    *package.json)
      sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' <<<"$content" | head -1
      ;;
  esac
}

version_in_file() {
  local file="$1"
  extract_version "$file" "$(cat "$file" 2>/dev/null || true)"
}
