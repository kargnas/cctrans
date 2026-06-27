#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}/.."
APP_NAME="CCTrans"
GITHUB_REPO="kargnas/cctrans"
INSTALL_DIR="/Applications"
OPEN_AFTER_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --open)
      OPEN_AFTER_INSTALL=1
      shift
      ;;
    -h|--help)
      cat <<HELP
Usage: scripts/install-app.zsh [--install-dir PATH] [--open]

Builds CCTrans.app and installs it to PATH.
Default install directory: /Applications
HELP
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

"$ROOT/scripts/build-app.zsh"

APP_DIR="$ROOT/dist/$APP_NAME.app"
DEST="$INSTALL_DIR/$APP_NAME.app"

install_app_bundle() {
  local source_app="$1"
  local dest_app="$2"

  if rm -rf "$dest_app" 2>/dev/null && ditto "$source_app" "$dest_app" 2>/dev/null; then
    return 0
  fi

  echo "Administrator permission required to replace: $dest_app"
  /usr/bin/osascript - "$source_app" "$dest_app" <<'APPLESCRIPT'
on run argv
  set sourcePath to item 1 of argv
  set destPath to item 2 of argv
  do shell script "/bin/rm -rf " & quoted form of destPath & " && /usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of destPath with administrator privileges
end run
APPLESCRIPT
}

mkdir -p "$INSTALL_DIR"
install_app_bundle "$APP_DIR" "$DEST"

echo "Installed: $DEST"
echo "Open System Settings permissions if this is the first install on this Mac:"
echo '  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"'
echo '  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"'
echo '  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"'

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  open "$DEST"
fi

# Best-effort GitHub star nudge for from-source installers. The install is
# already done at this point, and `set -e` is active, so every gh call must
# stay inside a condition to keep a gh/network hiccup from failing the script.
if [[ -t 0 ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  # GET user/starred/<repo> exits 0 only when the repo is already starred
  # (HTTP 204); 404 means not starred, so only then we prompt.
  if ! gh api "user/starred/$GITHUB_REPO" >/dev/null 2>&1; then
    if read -q "REPLY?Enjoying CCTrans? Star https://github.com/$GITHUB_REPO [y/N] "; then
      echo ""
      if gh api -X PUT "user/starred/$GITHUB_REPO" >/dev/null 2>&1; then
        echo "Starred $GITHUB_REPO. Thanks!"
      else
        echo "Could not star $GITHUB_REPO (gh api PUT failed; check token scopes)." >&2
      fi
    else
      echo ""
    fi
  fi
  # The installed app has its own one-time star prompt (GitHubStarPrompter).
  # Mark it handled in the app's defaults domain so clone users who were just
  # asked here (or are already starred) never get asked a second time in-app.
  defaults write as.kargn.cctrans githubStarPromptHandled -bool true || true
fi
