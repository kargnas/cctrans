#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="CCTrans"
APP_BUNDLE_NAME="CCTrans MAS Dev"
INSTALL_DIR="/Applications"
OPEN_AFTER_INSTALL=0
APP_ARGS=()

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
    --)
      shift
      APP_ARGS+=("$@")
      break
      ;;
    -h|--help)
      cat <<HELP
Usage: scripts/install-mas-local.zsh [--install-dir PATH] [--open] [-- APP_ARGS...]

Builds the local Mac App Store variant and installs CCTrans MAS Dev.app to PATH.
Default install directory: /Applications
HELP
      exit 0
      ;;
    *)
      APP_ARGS+=("$1")
      shift
      ;;
  esac
done

stop_running_cctrans() {
  local root="$ROOT"
  local -a pids
  pids=(${(f)"$(ps -axo pid=,command= | awk -v root="$root" '
    /awk/ { next }
    /\/Applications\/CCTrans\.app\/Contents\// { print $1; next }
    /\/Applications\/CCTrans 2\.app\/Contents\// { print $1; next }
    index($0, root "/dist/") && index($0, "CCTrans") && index($0, ".app/Contents/") { print $1; next }
    index($0, root "/dist-mas/") && index($0, "CCTrans") && index($0, ".app/Contents/") { print $1; next }
  ')"})
  (( ${#pids[@]} == 0 )) && return
  kill "${pids[@]}" 2>/dev/null || true
  for _ in {1..20}; do
    sleep 0.1
    pids=(${(f)"$(ps -axo pid=,command= | awk -v root="$root" '
      /awk/ { next }
      /\/Applications\/CCTrans\.app\/Contents\// { print $1; next }
      /\/Applications\/CCTrans 2\.app\/Contents\// { print $1; next }
      index($0, root "/dist/") && index($0, "CCTrans") && index($0, ".app/Contents/") { print $1; next }
      index($0, root "/dist-mas/") && index($0, "CCTrans") && index($0, ".app/Contents/") { print $1; next }
    ')"})
    (( ${#pids[@]} == 0 )) && return
  done
  kill -9 "${pids[@]}" 2>/dev/null || true
}

CCTRANS_MAS_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
CCTRANS_MAS_APP_DISPLAY_NAME="$APP_BUNDLE_NAME" \
CCTRANS_MAS_BUNDLE_ID="as.kargn.cctrans.mas-dev" \
CCTRANS_MAS_HELPER_BUNDLE_ID="as.kargn.cctrans.mas-dev.helper" \
  "$ROOT/scripts/build-mas.zsh"
"$ROOT/scripts/seed-mas-dev-credentials.zsh" "as.kargn.cctrans.mas-dev"

APP_DIR="$ROOT/dist-mas/$APP_BUNDLE_NAME.app"
DEST="$INSTALL_DIR/$APP_BUNDLE_NAME.app"

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

stop_running_cctrans
mkdir -p "$INSTALL_DIR"
install_app_bundle "$APP_DIR" "$DEST"

echo "Installed local MAS variant: $DEST"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  if [[ "${#APP_ARGS[@]}" -gt 0 ]]; then
    open "$DEST" --args "${APP_ARGS[@]}"
  else
    open "$DEST"
  fi
fi
