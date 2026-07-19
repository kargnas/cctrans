#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}/.."
APP_NAME="CCTrans"
APP_BUNDLE_NAME="${CCTRANS_APP_BUNDLE_NAME:-$APP_NAME}"
APP_DISPLAY_NAME="${CCTRANS_APP_DISPLAY_NAME:-$APP_BUNDLE_NAME}"
BUNDLE_ID="${CCTRANS_BUNDLE_ID:-as.kargn.cctrans}"
HELPER_BUNDLE_ID="${CCTRANS_HELPER_BUNDLE_ID:-$BUNDLE_ID.helper}"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SIGN_IDENTITY="${CCTRANS_CODE_SIGN_IDENTITY:-}"
KEYCHAIN_ACCESS_GROUP="6YQH3QFFK8.as.kargn.cctrans"
KEYCHAIN_TEAM_ID="${KEYCHAIN_ACCESS_GROUP%%.*}"
PROFILE_PATH="${CCTRANS_DIRECT_PROFILE:-}"
HELPER_PROFILE_PATH="${CCTRANS_DIRECT_HELPER_PROFILE:-}"
# CI injects the release version from the git tag; local builds fall back to 0.1.0.
APP_VERSION="${CCTRANS_VERSION:-0.1.0}"
# Sparkle EdDSA public key. The matching private key lives in the login keychain
# (account "CCTrans") and as the SPARKLE_PRIVATE_KEY GitHub secret.
SPARKLE_PUBLIC_ED_KEY="I/4kuK5XwH6K5pV0Bu+Y1DM99U4SfRO3ZTZdiZXhfgM="
SPARKLE_FEED_URL="https://github.com/kargnas/cctrans/releases/latest/download/appcast.xml"
# Local dev builds reuse version 0.1.0, so automatic checks would keep replacing
# the dev bundle with the latest release on quit. Release builds (CI) enable them.
if [[ "${CCTRANS_HARDENED_RUNTIME:-0}" == "1" ]]; then
  SPARKLE_AUTO_CHECKS="true"
else
  SPARKLE_AUTO_CHECKS="false"
fi
TAURI_HELPER_SOURCE="$ROOT/src-tauri/target/release/bundle/macos/CCTrans.app"
TAURI_HELPER_DEST="$RESOURCES_DIR/CCTransTauri.app"

if [[ -n "$PROFILE_PATH" || -n "$HELPER_PROFILE_PATH" ]]; then
  if [[ -z "$PROFILE_PATH" || -z "$HELPER_PROFILE_PATH" ]]; then
    echo "ERROR: direct Keychain sharing requires both CCTRANS_DIRECT_PROFILE and CCTRANS_DIRECT_HELPER_PROFILE." >&2
    exit 1
  fi
fi
if [[ "${CCTRANS_HARDENED_RUNTIME:-0}" == "1" && -z "$PROFILE_PATH" ]]; then
  echo "ERROR: release signing requires CCTRANS_DIRECT_PROFILE and CCTRANS_DIRECT_HELPER_PROFILE for shared account Keychain access." >&2
  exit 1
fi

cd "$ROOT"
swift build -c release
# `tauri build` runs `vite build` (fresh dist-web) then cargo, which embeds dist-web via
# `generate_context!` at lib.rs compile time. But cargo does NOT recompile lib.rs when only the frontend
# (CSS/Svelte) changed, so a frontend-only edit otherwise ships STALE embedded assets — the toast keeps
# rendering the previous build's CSS. Touch lib.rs to force the recompile + re-embed of the new dist-web.
touch src-tauri/src/lib.rs
npm run tauri -- build --bundles app >/dev/null

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
# SwiftPM links Sparkle as @rpath/Sparkle.framework but does not embed it, so the
# bundle must carry the framework and the executable needs a matching rpath.
ditto ".build/release/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME"
ditto "$TAURI_HELPER_SOURCE" "$TAURI_HELPER_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_BUNDLE_ID" "$TAURI_HELPER_DEST/Contents/Info.plist"
# User-visible name matches the outer app: the helper owns the Settings window
# and the toast, and macOS shows CFBundleName in the menu bar / Mission Control
# for the frontmost app — "CCTransTauri" leaking there reads like a different
# app. The bundle FOLDER keeps the CCTransTauri.app name (paths reference it).
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$TAURI_HELPER_DEST/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$TAURI_HELPER_DEST/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$TAURI_HELPER_DEST" >/dev/null 2>&1 || true
cp "$ROOT/assets/icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT/scripts/hy_mt2_translate.py" "$RESOURCES_DIR/hy_mt2_translate.py"
mkdir -p "$RESOURCES_DIR/runtimes"
cp "$ROOT"/scripts/runtimes/*.py "$RESOURCES_DIR/runtimes/"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_BUNDLE_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <$SPARKLE_AUTO_CHECKS/>
  <key>SUAutomaticallyUpdate</key>
  <$SPARKLE_AUTO_CHECKS/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Sangrak</string>
</dict>
</plist>
PLIST

if [[ -n "$PROFILE_PATH" ]]; then
  cp "$PROFILE_PATH" "$CONTENTS_DIR/embedded.provisionprofile"
  cp "$HELPER_PROFILE_PATH" "$TAURI_HELPER_DEST/Contents/embedded.provisionprofile"
fi

identity_for_team() {
  local certificate_kind="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^ *[0-9]*) \\([A-F0-9]\\{40\\}\\) \"${certificate_kind}:[^\"]*(${KEYCHAIN_TEAM_ID})\".*/\\1/p" \
    | head -n 1
}

identity_matches_keychain_team() {
  local identity="$1"
  [[ "$identity" != "-" ]] || return 1
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$identity" \
    | grep -q "($KEYCHAIN_TEAM_ID)"
}

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(identity_for_team "Apple Development")"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(identity_for_team "Developer ID Application")"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^ *[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^ *[0-9]*) \([A-F0-9]\{40\}\) "Developer ID Application:[^"]*".*/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
DIRECT_ENTITLEMENTS="$WORK_DIR/CCTrans-direct.entitlements"
DIRECT_HELPER_ENTITLEMENTS="$WORK_DIR/CCTransTauri-direct.entitlements"
cat > "$DIRECT_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$KEYCHAIN_TEAM_ID.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key>
  <string>$KEYCHAIN_TEAM_ID</string>
  <key>keychain-access-groups</key>
  <array>
    <string>$KEYCHAIN_ACCESS_GROUP</string>
  </array>
</dict>
</plist>
PLIST
cat > "$DIRECT_HELPER_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$KEYCHAIN_TEAM_ID.$HELPER_BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key>
  <string>$KEYCHAIN_TEAM_ID</string>
  <key>keychain-access-groups</key>
  <array>
    <string>$KEYCHAIN_ACCESS_GROUP</string>
  </array>
</dict>
</plist>
PLIST

profile_allows_keychain_group() {
  local profile="$1"
  local expected_app_id="$2"
  local decoded="$WORK_DIR/$(basename "$profile").plist"
  security cms -D -i "$profile" > "$decoded"
  local app_id
  app_id="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)"
  if [[ "$app_id" != "$expected_app_id" ]]; then
    echo "ERROR: provisioning profile application identifier must be $expected_app_id: $profile" >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$decoded" 2>/dev/null \
      | grep -Eq "${KEYCHAIN_ACCESS_GROUP//./\\.}|${KEYCHAIN_TEAM_ID}\\.\\*"; then
    return
  fi
  echo "ERROR: provisioning profile does not allow Keychain group $KEYCHAIN_ACCESS_GROUP: $profile" >&2
  exit 1
}

if [[ -n "$PROFILE_PATH" ]]; then
  profile_allows_keychain_group "$PROFILE_PATH" "$KEYCHAIN_TEAM_ID.$BUNDLE_ID"
  profile_allows_keychain_group "$HELPER_PROFILE_PATH" "$KEYCHAIN_TEAM_ID.$HELPER_BUNDLE_ID"
fi

APP_ENTITLEMENT_OPTS=()
HELPER_ENTITLEMENT_OPTS=()
if [[ -n "$PROFILE_PATH" ]] && identity_matches_keychain_team "$SIGN_IDENTITY"; then
  APP_ENTITLEMENT_OPTS=(--entitlements "$DIRECT_ENTITLEMENTS")
  HELPER_ENTITLEMENT_OPTS=(--entitlements "$DIRECT_HELPER_ENTITLEMENTS")
elif [[ -n "$PROFILE_PATH" ]]; then
  echo "ERROR: direct profile signing identity must belong to Keychain team $KEYCHAIN_TEAM_ID." >&2
  exit 1
fi

# Notarization requires hardened runtime + secure timestamp on every nested
# executable. CI sets CCTRANS_HARDENED_RUNTIME=1; local dev builds skip it.
SIGN_OPTS=()
if [[ "${CCTRANS_HARDENED_RUNTIME:-0}" == "1" ]]; then
  SIGN_OPTS=(--options runtime --timestamp)
fi

sign_bundle_tree() {
  local identity="$1"
  local sparkle_b="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
  # Sparkle ships its own helper executables; sign inside-out so the outer
  # signatures seal already-valid inner ones. --deep would strip the
  # Downloader.xpc sandbox entitlement, so each piece is signed explicitly.
  codesign --force "${SIGN_OPTS[@]}" --sign "$identity" "$sparkle_b/Autoupdate"
  codesign --force "${SIGN_OPTS[@]}" --sign "$identity" "$sparkle_b/Updater.app"
  codesign --force "${SIGN_OPTS[@]}" --preserve-metadata=entitlements --sign "$identity" "$sparkle_b/XPCServices/Downloader.xpc"
  codesign --force "${SIGN_OPTS[@]}" --sign "$identity" "$sparkle_b/XPCServices/Installer.xpc"
  codesign --force "${SIGN_OPTS[@]}" --sign "$identity" "$FRAMEWORKS_DIR/Sparkle.framework"
  # The helper and outer app share the account-token Keychain group only when
  # both matching provisioning profiles are embedded. Profile-free local builds
  # omit the restricted entitlement and keep the existing dev flow intact.
  codesign --force --deep "${SIGN_OPTS[@]}" "${HELPER_ENTITLEMENT_OPTS[@]}" --sign "$identity" "$TAURI_HELPER_DEST"
  codesign --force "${SIGN_OPTS[@]}" "${APP_ENTITLEMENT_OPTS[@]}" --sign "$identity" "$APP_DIR"
}

if ! sign_bundle_tree "$SIGN_IDENTITY" >/dev/null 2>&1; then
  if [[ "${CCTRANS_HARDENED_RUNTIME:-0}" == "1" || -n "$PROFILE_PATH" ]]; then
    # Release builds must never ship ad-hoc signed; surface the failure loudly.
    echo "Release signing failed with identity: $SIGN_IDENTITY" >&2
    sign_bundle_tree "$SIGN_IDENTITY"
    exit 1
  fi
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "codesign with detected identity failed; falling back to ad-hoc signing." >&2
    SIGN_IDENTITY="-"
    APP_ENTITLEMENT_OPTS=()
    HELPER_ENTITLEMENT_OPTS=()
  else
    sleep 0.5
  fi
  sign_bundle_tree "$SIGN_IDENTITY" >/dev/null
fi
codesign --verify --deep --strict "$APP_DIR"
if (( ${#APP_ENTITLEMENT_OPTS[@]} > 0 )); then
  for BUNDLE in "$APP_DIR" "$TAURI_HELPER_DEST"; do
    if ! codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null \
        | grep -q "$KEYCHAIN_ACCESS_GROUP"; then
      echo "ERROR: shared Keychain access group missing from $BUNDLE" >&2
      exit 1
    fi
  done
fi
echo "Signed with: $SIGN_IDENTITY"
echo "$APP_DIR"
