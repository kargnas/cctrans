#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_BUNDLE_NAME="CCTrans MAS Dev"
APP_DIR="$ROOT/dist-mas/$APP_BUNDLE_NAME.app"

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
stop_running_cctrans
open -n "$APP_DIR" --args --show-settings "$@"
