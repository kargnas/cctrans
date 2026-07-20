#!/usr/bin/env zsh
set -euo pipefail

# Mac App Store variant of build-app.zsh. Differences, per docs/mac-app-store.md:
#   - CCTRANS_MAS_BUILD=1 swift build: Package.swift drops Sparkle and defines
#     MAS_BUILD (separate scratch path so the manifest cache never mixes).
#   - No Sparkle framework, rpath, or SU* Info.plist keys in the bundle.
#   - No Python local-model runtime files (the sandbox cannot run them, and
#     shipping downloadable-code machinery invites 2.5.2 questions).
#   - Sandbox entitlements on the helper and the outer app.
#
# Two modes:
#   Local verification (default): ad-hoc or Apple Development signing, no
#     identifier entitlements, no .pkg. Confirms the MAS compile/bundle shape.
#     By default this local mode strips sandbox/app-group entitlements so running
#     the ad-hoc bundle does not trigger macOS "access data from other apps"
#     prompts against the production App Group. Set CCTRANS_MAS_LOCAL_SANDBOX=1
#     when specifically testing sandbox entitlements with real profiles.
#   Submission: set CCTRANS_MAS_SIGN_IDENTITY ("Apple Distribution: ..."),
#     CCTRANS_TEAM_ID, CCTRANS_MAS_PROFILE (Mac App Store provisioning profile
#     for as.kargn.cctrans), CCTRANS_MAS_HELPER_PROFILE (Mac App Store
#     provisioning profile for the nested helper), and optionally
#     CCTRANS_MAS_INSTALLER_IDENTITY ("3rd Party Mac Developer Installer: ...")
#     to also produce the uploadable .pkg for Transporter / altool
#     --upload-package.

ROOT="${0:A:h}/.."
APP_NAME="CCTrans"
DIST_DIR="$ROOT/dist-mas"
APP_VERSION="${CCTRANS_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${CCTRANS_BUILD_NUMBER:-$APP_VERSION}"
SIGN_IDENTITY="${CCTRANS_MAS_SIGN_IDENTITY:-}"
TEAM_ID="${CCTRANS_TEAM_ID:-}"
PROFILE_PATH="${CCTRANS_MAS_PROFILE:-}"
HELPER_PROFILE_PATH="${CCTRANS_MAS_HELPER_PROFILE:-}"
INSTALLER_IDENTITY="${CCTRANS_MAS_INSTALLER_IDENTITY:-}"
LOCAL_SANDBOX="${CCTRANS_MAS_LOCAL_SANDBOX:-0}"
KEYCHAIN_ACCESS_GROUP="6YQH3QFFK8.as.kargn.cctrans"
LOCAL_VERIFICATION=0
if [[ -z "$PROFILE_PATH" && -z "$HELPER_PROFILE_PATH" && -z "$TEAM_ID" && "$LOCAL_SANDBOX" != "1" ]]; then
  LOCAL_VERIFICATION=1
fi
if [[ "$LOCAL_VERIFICATION" == "1" ]]; then
  APP_BUNDLE_NAME="${CCTRANS_MAS_APP_BUNDLE_NAME:-CCTrans MAS Dev}"
  APP_DISPLAY_NAME="${CCTRANS_MAS_APP_DISPLAY_NAME:-$APP_BUNDLE_NAME}"
  BUNDLE_ID="${CCTRANS_MAS_BUNDLE_ID:-as.kargn.cctrans.mas-dev}"
else
  APP_BUNDLE_NAME="${CCTRANS_MAS_APP_BUNDLE_NAME:-$APP_NAME}"
  APP_DISPLAY_NAME="${CCTRANS_MAS_APP_DISPLAY_NAME:-$APP_BUNDLE_NAME}"
  BUNDLE_ID="${CCTRANS_MAS_BUNDLE_ID:-as.kargn.cctrans}"
fi
HELPER_BUNDLE_ID="${CCTRANS_MAS_HELPER_BUNDLE_ID:-$BUNDLE_ID.helper}"

if [[ "$LOCAL_VERIFICATION" == "0" ]]; then
  if [[ -z "$TEAM_ID" || -z "$PROFILE_PATH" || -z "$HELPER_PROFILE_PATH" ]]; then
    echo "ERROR: sandboxed MAS signing requires CCTRANS_TEAM_ID, CCTRANS_MAS_PROFILE, and CCTRANS_MAS_HELPER_PROFILE." >&2
    exit 1
  fi
  if [[ "$KEYCHAIN_ACCESS_GROUP" != "$TEAM_ID."* ]]; then
    echo "ERROR: the shared Keychain group must use the CCTRANS_TEAM_ID prefix." >&2
    exit 1
  fi
fi
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS_SRC="$ROOT/scripts/mas/CCTrans.entitlements"
HELPER_ENTITLEMENTS_SRC="$ROOT/scripts/mas/CCTransTauri.entitlements"
# Inherited-sandbox CLI helper: a copy of the main binary the Tauri helper
# fork-execs. Signed with app-sandbox + inherit only (see the file's comment and
# §3.6 of docs/mac-app-store.md) so it does not trap in _libsecinit_appsandbox.
CLI_ENTITLEMENTS_SRC="$ROOT/scripts/mas/cctrans-cli.entitlements"
TAURI_HELPER_SOURCE="$ROOT/src-tauri/target/release/bundle/macos/CCTrans.app"
TAURI_HELPER_DEST="$RESOURCES_DIR/CCTransTauri.app"
# cctrans-cli lives next to cctrans-tauri so the helper resolves it as a sibling.
CLI_HELPER_DEST="$TAURI_HELPER_DEST/Contents/MacOS/cctrans-cli"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

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
      | grep -Eq "${KEYCHAIN_ACCESS_GROUP//./\\.}|${TEAM_ID}\\.\\*"; then
    return
  fi
  echo "ERROR: provisioning profile does not allow Keychain group $KEYCHAIN_ACCESS_GROUP: $profile" >&2
  exit 1
}

if [[ "$LOCAL_VERIFICATION" == "0" ]]; then
  profile_allows_keychain_group "$PROFILE_PATH" "$TEAM_ID.$BUNDLE_ID"
  profile_allows_keychain_group "$HELPER_PROFILE_PATH" "$TEAM_ID.$HELPER_BUNDLE_ID"
fi
if [[ "${CCTRANS_PROFILE_VALIDATION_ONLY:-0}" == "1" ]]; then
  if [[ "$LOCAL_VERIFICATION" == "1" ]]; then
    echo "ERROR: profile validation requires the MAS team and both provisioning profiles." >&2
    exit 1
  fi
  echo "MAS provisioning profiles validated."
  exit 0
fi

cd "$ROOT"
CCTRANS_MAS_BUILD=1 swift build -c release --scratch-path .build-mas
npm run tauri -- build --bundles app >/dev/null

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build-mas/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
ditto "$TAURI_HELPER_SOURCE" "$TAURI_HELPER_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_BUNDLE_ID" "$TAURI_HELPER_DEST/Contents/Info.plist"
# User-visible name matches the outer app (matches build-app.zsh): CFBundleName
# shows in the menu bar / Mission Control while the helper's Settings window is
# frontmost. The bundle FOLDER keeps the CCTransTauri.app name (paths reference it).
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$TAURI_HELPER_DEST/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$TAURI_HELPER_DEST/Contents/Info.plist"
cp "$ROOT/assets/icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>as.kargn.cctrans.oauth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>cctrans</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Sangrak</string>
  <!-- Standard HTTPS only (ATS/URLSession), so the app is exempt from export
       compliance; declaring it here suppresses the per-build ASC question. -->
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
</dict>
</plist>
PLIST

if [[ -n "$PROFILE_PATH" ]]; then
  cp "$PROFILE_PATH" "$CONTENTS_DIR/embedded.provisionprofile"
fi
if [[ -n "$HELPER_PROFILE_PATH" ]]; then
  cp "$HELPER_PROFILE_PATH" "$TAURI_HELPER_DEST/Contents/embedded.provisionprofile"
fi

# Working copies of the entitlements; identifier keys are appended only when a
# team id is available because they must match the provisioning profile.
APP_ENTITLEMENTS="$WORK_DIR/CCTrans.entitlements"
HELPER_ENTITLEMENTS="$WORK_DIR/CCTransTauri.entitlements"
# No work copy / identifier keys for the CLI: an inherited-sandbox helper must
# carry neither application-identifier nor application-groups (it inherits them).
CLI_ENTITLEMENTS="$CLI_ENTITLEMENTS_SRC"
cp "$ENTITLEMENTS_SRC" "$APP_ENTITLEMENTS"
cp "$HELPER_ENTITLEMENTS_SRC" "$HELPER_ENTITLEMENTS"

if [[ -n "$TEAM_ID" ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$HELPER_BUNDLE_ID" "$HELPER_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$HELPER_ENTITLEMENTS"
fi
USE_SANDBOX_ENTITLEMENTS=1
if [[ "$LOCAL_VERIFICATION" == "1" ]]; then
  USE_SANDBOX_ENTITLEMENTS=0
  cat > "$APP_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  cp "$APP_ENTITLEMENTS" "$HELPER_ENTITLEMENTS"
  CLI_ENTITLEMENTS="$APP_ENTITLEMENTS"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  # Local verification fallback: Apple Development if present, else ad-hoc.
  # Restricted identifier entitlements would break ad-hoc signed launches,
  # which is why they are gated on TEAM_ID above.
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^ *[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
      | head -n 1
  )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

# Bundle the inherited-sandbox CLI helper next to cctrans-tauri. It is the same
# binary as the main app but signed to inherit the Tauri helper's sandbox, so the
# helper can fork-exec it without the _libsecinit_appsandbox launch trap.
cp "$MACOS_DIR/$APP_NAME" "$CLI_HELPER_DEST"

# Inside-out signing. The helper is signed --deep first; that pass would strip
# cctrans-cli's inherit entitlements, so re-sign it explicitly and then re-seal
# the helper bundle (a plain re-sign, NOT --deep, preserves cctrans-cli's
# signature while refreshing the bundle's CodeResources). Then the outer app.
# No hardened runtime here — that is a Developer ID concept; MAS ingest cares
# about the sandbox entitlement instead.
codesign --force --deep --entitlements "$HELPER_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$TAURI_HELPER_DEST"
codesign --force --entitlements "$CLI_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$CLI_HELPER_DEST"
codesign --force --entitlements "$HELPER_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$TAURI_HELPER_DEST"
codesign --force --entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# Fail the build if the CLI helper did not end up with the inherit entitlement —
# without it the helper would crash on first fork-exec under the App Sandbox.
if [[ "$USE_SANDBOX_ENTITLEMENTS" == "1" ]]; then
  if ! codesign -d --entitlements - --xml "$CLI_HELPER_DEST" 2>/dev/null \
      | plutil -convert xml1 -o - - 2>/dev/null \
      | grep -q "com.apple.security.inherit"; then
    echo "ERROR: cctrans-cli is missing com.apple.security.inherit after signing." >&2
    exit 1
  fi
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
if [[ "$USE_SANDBOX_ENTITLEMENTS" == "0" ]]; then
  echo "Local MAS verification mode: sandbox/app-group entitlements stripped."
fi
echo "$APP_DIR"

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  productbuild --component "$APP_DIR" /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$DIST_DIR/$APP_NAME-mas-$APP_VERSION.pkg"
  echo "$DIST_DIR/$APP_NAME-mas-$APP_VERSION.pkg"
else
  echo "No CCTRANS_MAS_INSTALLER_IDENTITY set; skipped .pkg (local verification mode)."
fi
