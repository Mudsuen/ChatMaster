#!/usr/bin/env bash
# Builds dist/ChatMaster.app (release by default) and signs it with a stable identity so macOS
# privacy permissions (Accessibility, Screen Recording, App Data) survive rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/dist/ChatMaster.app"
IDENTITY="${CHATMASTER_SIGN_IDENTITY:-${WECHATLENS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')}}"

cd "$ROOT"
swift build -c "$CONFIG" --product ChatMaster 2>&1 | grep -v "was built for newer 'macOS' version" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ChatMaster"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing" >&2; exit 1; }

if [[ ! -f Packaging/AppIcon.icns || script/make_icon.swift -nt Packaging/AppIcon.icns ]]; then
  swift script/make_icon.swift Packaging/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChatMaster"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COUNT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ChatMasterSourceCommit string $COMMIT" "$APP/Contents/Info.plist"

if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.mudsuen.ChatMaster "$APP"
else
  echo "warning: signing identity not found, using ad-hoc signature" >&2
  codesign --force --sign - --identifier com.mudsuen.ChatMaster "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($COMMIT, $CONFIG)"
