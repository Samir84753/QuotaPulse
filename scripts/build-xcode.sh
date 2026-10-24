#!/usr/bin/env bash
# Generates QuotaPulse.xcodeproj with XcodeGen and builds the Release configuration.
# Usage:
#   ./scripts/build-xcode.sh
#   QUOTAPULSE_TEAM_ID=XXXXXXXXXX ./scripts/build-xcode.sh
#   ./scripts/build-xcode.sh CODE_SIGNING_ALLOWED=NO
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

echo "==> Generating Xcode project..."
xcodegen generate

BUILD_ARGS=("-project" "QuotaPulse.xcodeproj" "-scheme" "QuotaPulseApp" "-configuration" "Release" "-destination" "generic/platform=macOS")

# If QUOTAPULSE_TEAM_ID is set in env, pass it as build setting
if [[ -n "${QUOTAPULSE_TEAM_ID:-}" ]]; then
    BUILD_ARGS+=("DEVELOPMENT_TEAM=${QUOTAPULSE_TEAM_ID}")
else
    CONFIGURED_TEAM="$(awk -F= '$1 ~ /^[[:space:]]*QUOTAPULSE_TEAM_ID[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2}' Config.xcconfig)"
    if [[ -z "$CONFIGURED_TEAM" && " $* " != *"CODE_SIGN"* && " $* " != *"DEVELOPMENT_TEAM="* ]]; then
        # Compile unsigned by default; honor teams configured in xcconfig or arguments.
        BUILD_ARGS+=("CODE_SIGNING_ALLOWED=NO")
    fi
fi

echo "==> Building QuotaPulse with xcodebuild..."
xcodebuild "${BUILD_ARGS[@]}" "$@" build
