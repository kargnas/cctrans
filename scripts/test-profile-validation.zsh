#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}/.."
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TEAM_ID="6YQH3QFFK8"
KEYCHAIN_GROUP="$TEAM_ID.as.kargn.cctrans"
MAIN_PROFILE="$WORK_DIR/main.provisionprofile"
HELPER_PROFILE="$WORK_DIR/helper.provisionprofile"
BIN_DIR="$WORK_DIR/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/security" <<'SCRIPT'
#!/bin/zsh
if [[ "${1:-}" == "cms" && "${2:-}" == "-D" && "${3:-}" == "-i" && -n "${4:-}" ]]; then
  cat "$4"
  exit 0
fi
echo "unexpected security invocation: $*" >&2
exit 97
SCRIPT

for tool in swift npm; do
  cat > "$BIN_DIR/$tool" <<SCRIPT
#!/bin/zsh
echo "unexpected $tool invocation during profile validation probe" >&2
exit 97
SCRIPT
done
chmod +x "$BIN_DIR/security" "$BIN_DIR/swift" "$BIN_DIR/npm"

write_profile() {
  local profile_path="$1"
  local app_id="$2"
  local keychain_group="$3"
  cat > "$profile_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key>
    <string>$app_id</string>
    <key>keychain-access-groups</key>
    <array>
      <string>$keychain_group</string>
    </array>
  </dict>
</dict>
</plist>
PLIST
}

run_probe() {
  env \
    PATH="$BIN_DIR:$PATH" \
    CCTRANS_PROFILE_VALIDATION_ONLY=1 \
    CCTRANS_TEAM_ID="$TEAM_ID" \
    CCTRANS_MAS_PROFILE="$MAIN_PROFILE" \
    CCTRANS_MAS_HELPER_PROFILE="$HELPER_PROFILE" \
    "$ROOT/scripts/build-mas.zsh"
}

write_profile "$MAIN_PROFILE" "$TEAM_ID.as.kargn.cctrans" "$KEYCHAIN_GROUP"
write_profile "$HELPER_PROFILE" "$TEAM_ID.as.kargn.cctrans.helper" "$KEYCHAIN_GROUP"
run_probe >/dev/null

write_profile "$HELPER_PROFILE" "$TEAM_ID.as.kargn.cctrans.wrong-helper" "$KEYCHAIN_GROUP"
if output="$(run_probe 2>&1)"; then
  echo "ERROR: helper application-identifier mismatch was accepted." >&2
  exit 1
fi
if [[ "$output" != *"provisioning profile application identifier must be $TEAM_ID.as.kargn.cctrans.helper"* ]]; then
  echo "ERROR: helper identifier probe did not fail with the expected message." >&2
  echo "$output" >&2
  exit 1
fi

write_profile "$HELPER_PROFILE" "$TEAM_ID.as.kargn.cctrans.helper" "$TEAM_ID.wrong-group"
if output="$(run_probe 2>&1)"; then
  echo "ERROR: helper Keychain group mismatch was accepted." >&2
  exit 1
fi
if [[ "$output" != *"does not allow Keychain group $KEYCHAIN_GROUP"* ]]; then
  echo "ERROR: helper Keychain group probe did not fail with the expected message." >&2
  echo "$output" >&2
  exit 1
fi

echo "MAS profile validation probes passed."
