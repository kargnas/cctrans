#!/usr/bin/env zsh
set -euo pipefail

HOST_APP_ID="${1:-as.kargn.cctrans.mas-dev}"
DEST_DIR="$HOME/Library/Application Support/$HOST_APP_ID"
DEST_FILE="$DEST_DIR/credentials.env"

trim_env_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:-1}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:-1}"
  fi
  print -r -- "$value"
}

read_dev_token_from_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local line value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      CCTRANS_DEV_TOKEN=*)
        value="${line#CCTRANS_DEV_TOKEN=}"
        trim_env_value "$value"
        return 0
        ;;
      export\ CCTRANS_DEV_TOKEN=*)
        value="${line#export CCTRANS_DEV_TOKEN=}"
        trim_env_value "$value"
        return 0
        ;;
    esac
  done < "$path"
  return 1
}

TOKEN="${CCTRANS_DEV_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(read_dev_token_from_file "$HOME/.config/cctrans/.env" 2>/dev/null || true)"
fi

if [[ -z "$TOKEN" ]]; then
  echo "No CCTRANS_DEV_TOKEN found for local MAS Cloud QA."
  echo "Set CCTRANS_DEV_TOKEN in the environment or ~/.config/cctrans/.env to test CCTrans Cloud locally."
  exit 0
fi

mkdir -p "$DEST_DIR"
TMP_FILE="$DEST_FILE.tmp.$$"
if [[ -f "$DEST_FILE" ]]; then
  grep -v '^CCTRANS_DEV_TOKEN=' "$DEST_FILE" > "$TMP_FILE" || true
else
  : > "$TMP_FILE"
fi
printf 'CCTRANS_DEV_TOKEN=%s\n' "$TOKEN" >> "$TMP_FILE"
chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$DEST_FILE"
echo "Seeded CCTRANS_DEV_TOKEN for local MAS Cloud QA: $DEST_FILE"
