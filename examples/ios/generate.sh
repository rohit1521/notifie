#!/usr/bin/env bash
# Regenerates NotifieDemo.xcodeproj.
#
# Simulator only (no Apple account needed):
#   ./generate.sh
#
# Real device (needs a paid team; push cannot be tested without one):
#   GK_TEAM_ID=ABCDE12345 GK_BUNDLE_ID=com.yourname.notifiedemo ./generate.sh
set -euo pipefail
cd "$(dirname "$0")"

export GK_BUNDLE_ID="${GK_BUNDLE_ID:-dev.notifie.demo}"
export GK_TEAM_ID="${GK_TEAM_ID:-}"

# The push entitlement is opt-in.
#
# Requesting aps-environment makes the build fail outright unless the
# provisioning profile already carries the Push Notifications capability —
# which needs a signed-in Xcode. Defaulting it off means the app still installs
# on a real device and events still flow, so you are not blocked on Apple
# paperwork just to see the SDK work.
if [ "${GK_PUSH:-0}" = "1" ]; then
  export GK_ENTITLEMENTS="NotifieDemo/NotifieDemo.entitlements"
  echo "Push entitlement ON — needs a profile with Push Notifications."
else
  export GK_ENTITLEMENTS=""
  echo "Push entitlement OFF (set GK_PUSH=1 to enable). Events work either way."
fi

if [ -z "$GK_TEAM_ID" ]; then
  echo "No GK_TEAM_ID — simulator-only project (a simulator cannot receive real push)."
else
  echo "Signing with team $GK_TEAM_ID as $GK_BUNDLE_ID"
fi

xcodegen generate
