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
#     identifier entitlements, no .pkg. Confirms the bundle shape and that
#     com.apple.security.app-sandbox lands on every executable.
#   Submission: set CCTRANS_MAS_SIGN_IDENTITY ("Apple Distribution: ..."),
#     CCTRANS_TEAM_ID, CCTRANS_MAS_PROFILE (Mac App Store provisioning profile
#     for as.kargn.cctrans), CCTRANS_MAS_HELPER_PROFILE (Mac App Store
#     provisioning profile for the nested helper), and optionally
#     CCTRANS_MAS_INSTALLER_IDENTITY ("3rd Party Mac Developer Installer: ...")
#     to also produce the uploadable .pkg for Transporter / altool
#     --upload-package.

ROOT="${0:A:h}/.."
APP_NAME="CCTrans"
BUNDLE_ID="as.kargn.cctrans"
HELPER_BUNDLE_ID="${CCTRANS_MAS_HELPER_BUNDLE_ID:-$BUNDLE_ID.helper}"
DIST_DIR="$ROOT/dist-mas"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_VERSION="${CCTRANS_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${CCTRANS_BUILD_NUMBER:-$APP_VERSION}"
SIGN_IDENTITY="${CCTRANS_MAS_SIGN_IDENTITY:-}"
TEAM_ID="${CCTRANS_TEAM_ID:-}"
PROFILE_PATH="${CCTRANS_MAS_PROFILE:-}"
HELPER_PROFILE_PATH="${CCTRANS_MAS_HELPER_PROFILE:-}"
INSTALLER_IDENTITY="${CCTRANS_MAS_INSTALLER_IDENTITY:-}"
ENTITLEMENTS_SRC="$ROOT/scripts/mas/CCTrans.entitlements"
HELPER_ENTITLEMENTS_SRC="$ROOT/scripts/mas/CCTransTauri.entitlements"
TAURI_HELPER_SOURCE="$ROOT/src-tauri/target/release/bundle/macos/CCTrans.app"
TAURI_HELPER_DEST="$RESOURCES_DIR/CCTransTauri.app"

cd "$ROOT"
CCTRANS_MAS_BUILD=1 swift build -c release --scratch-path .build-mas
npm run tauri -- build --bundles app >/dev/null

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build-mas/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
ditto "$TAURI_HELPER_SOURCE" "$TAURI_HELPER_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_BUNDLE_ID" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName CCTransTauri" "$TAURI_HELPER_DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName CCTransTauri" "$TAURI_HELPER_DEST/Contents/Info.plist"
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
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
APP_ENTITLEMENTS="$WORK_DIR/CCTrans.entitlements"
HELPER_ENTITLEMENTS="$WORK_DIR/CCTransTauri.entitlements"
cp "$ENTITLEMENTS_SRC" "$APP_ENTITLEMENTS"
cp "$HELPER_ENTITLEMENTS_SRC" "$HELPER_ENTITLEMENTS"
if [[ -n "$TEAM_ID" ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$HELPER_BUNDLE_ID" "$HELPER_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$HELPER_ENTITLEMENTS"
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

# Inside-out: helper first, then the outer app, each with its own sandbox
# entitlements. No hardened runtime here — that is a Developer ID concept;
# MAS ingest cares about the sandbox entitlement instead.
codesign --force --deep --entitlements "$HELPER_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$TAURI_HELPER_DEST"
codesign --force --entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Signed with: $SIGN_IDENTITY"
echo "$APP_DIR"

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  productbuild --component "$APP_DIR" /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$DIST_DIR/$APP_NAME-mas-$APP_VERSION.pkg"
  echo "$DIST_DIR/$APP_NAME-mas-$APP_VERSION.pkg"
else
  echo "No CCTRANS_MAS_INSTALLER_IDENTITY set; skipped .pkg (local verification mode)."
fi
