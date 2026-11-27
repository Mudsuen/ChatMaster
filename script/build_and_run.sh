#!/usr/bin/env bash
# Package, optionally install to /Applications, and launch ChatMaster.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ChatMaster"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) echo "Usage: $0 [--install]"; exit 0 ;;
  esac
done

for proc in "$APP_NAME" "WeChatLens"; do
  pkill -x "$proc" 2>/dev/null || true
  for _ in {1..20}; do pgrep -x "$proc" >/dev/null || break; sleep 0.2; done
  pkill -9 -x "$proc" 2>/dev/null || true
done

"$ROOT/script/package_app.sh" release

TARGET="$ROOT/dist/$APP_NAME.app"
if [[ "$INSTALL" == "1" ]]; then
  rm -rf "/Applications/WeChatLens.app" "/Applications/$APP_NAME.app"
  cp -R "$TARGET" "/Applications/$APP_NAME.app"
  xattr -cr "/Applications/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
  codesign --verify --strict "/Applications/$APP_NAME.app"
  TARGET="/Applications/$APP_NAME.app"
fi

open -n "$TARGET"
sleep 2
if pgrep -x "$APP_NAME" >/dev/null; then
  pgrep -al -x "$APP_NAME"
else
  echo "ERROR: $APP_NAME did not stay running." >&2
  exit 1
fi
