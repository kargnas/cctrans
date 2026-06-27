#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}/.."
ROOT="${ROOT:A}"
APP_NAME="CCTrans"
APP_BUNDLE_NAME="CCTrans Dev"
APP_DIR="$ROOT/dist/$APP_BUNDLE_NAME.app"
BUNDLE_ID="as.kargn.cctrans.dev"
APP_EXEC="$APP_DIR/Contents/MacOS/$APP_NAME"
DEBUG_EXEC="$ROOT/.build/arm64-apple-macosx/debug/$APP_NAME"
TAURI_HELPER_EXEC="$APP_DIR/Contents/Resources/CCTransTauri.app/Contents/MacOS/cctrans-tauri"

cd "$ROOT"

# Build and run the signed app bundle in development so macOS TCC permissions
# use a stable development bundle id instead of SwiftPM's ad-hoc debug executable
# id or the installed production app's id.
CCTRANS_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
CCTRANS_APP_DISPLAY_NAME="$APP_BUNDLE_NAME" \
CCTRANS_BUNDLE_ID="$BUNDLE_ID" \
CCTRANS_HELPER_BUNDLE_ID="$BUNDLE_ID.helper" \
  "$ROOT/scripts/build-app.zsh" >/dev/null

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
while IFS= read -r pid; do
  kill "$pid" >/dev/null 2>&1 || true
done < <(pgrep -f "$APP_EXEC" || true)

if [[ -x "$DEBUG_EXEC" ]]; then
  while IFS= read -r pid; do
    parent_pid="$(ps -p "$pid" -o ppid= | tr -d ' ' || true)"
    kill "$pid" >/dev/null 2>&1 || true
    if [[ -n "$parent_pid" ]] && ps -p "$parent_pid" -o comm= 2>/dev/null | grep -q "debugserver"; then
      kill "$parent_pid" >/dev/null 2>&1 || true
    fi
  done < <(pgrep -f "$DEBUG_EXEC" || true)
fi

if [[ -x "$TAURI_HELPER_EXEC" ]]; then
  while IFS= read -r pid; do
    kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "$TAURI_HELPER_EXEC" || true)
fi

open "$APP_DIR" --args --workspace-root "$ROOT" "$@"
echo "Opened: $APP_DIR"
