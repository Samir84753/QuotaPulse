#!/usr/bin/env bash
# Builds QuotaPulse.app (menu bar app) with the Xcode toolchain, ad-hoc signs it.
#   ./scripts/build.sh            # release build -> build/QuotaPulse.app
#   ./scripts/build.sh --install  # also copy to ~/Applications and launch
#   ./scripts/build.sh --test     # run unit tests first
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG=release

if [[ " $* " == *" --test "* ]]; then
  swift test 2>&1 | tail -30
fi

swift build -c "$CONFIG" --product QuotaPulse
BIN="$(swift build -c "$CONFIG" --show-bin-path)/QuotaPulse"

APP="$ROOT/build/QuotaPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaPulse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x QuotaPulse 2>/dev/null || true
  rm -rf "$HOME/Applications/QuotaPulse.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/QuotaPulse.app"
  echo "Installed and launched ~/Applications/QuotaPulse.app"
fi
