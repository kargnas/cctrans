# Mac App Store Release Plan

Status: **all code prep is done on the `mas-prep` branch (2026-06); nothing
submitted yet.** Done and verified: CGEventTap port (§3.2, both builds),
`MAS_BUILD` flag with Sparkle/caret/local-provider gates (§3.1/3.4), sandbox
entitlements + `scripts/build-mas.zsh` (§2/§4), the Apple Translation
framework provider (§3.3 — sandboxed end-to-end translation confirmed from the
`dist-mas` bundle), permission-helper trim and Tauri settings gating via
`--app-variant mas` (§3.5), and the App Group launch channel (§3.6 — GUI
toast + settings verified live from a sandboxed `dist-mas` launch).
Remaining before submission: only the
account-side work in §1/§5 (Apple Distribution + Mac Installer Distribution
certificates, Mac App Store provisioning profile, App Store Connect record,
metadata/review notes), which only the account holder can do, plus a TestFlight
QA pass of the .pkg. Direct distribution (DMG + brew + Sparkle) stays the
primary channel.

## TL;DR

The current app cannot ship to MAS as-is. Five things must change, in order of
pain — but research (see §8) shrank the damage: Cmd+C detection and local
translation both survive on MAS with API swaps instead of feature cuts:

| # | Today | MAS requirement | Plan |
|---|---|---|---|
| 1 | Sparkle self-update | Self-updating is forbidden; the store owns updates | Strip Sparkle from the MAS build (`MAS_BUILD` compile flag) |
| 2 | `NSEvent.addGlobalMonitorForEvents(.keyDown)` watches Cmd+C in other apps | The `NSEvent` global monitor rides the Accessibility privilege, which App Sandbox blocks. Per Apple DTS (Quinn), keyboard monitoring *does* work sandboxed through `CGEventTap` + the Input Monitoring privilege instead | Port `KeyboardMonitor` to a listen-only `CGEventTap` gated by `CGPreflightListenEventAccess`/`CGRequestListenEventAccess` (the preflight call is already in `AppDelegate`). Works in both builds, so the direct build can adopt it too. `PasteboardMonitor` stays as the no-permission fallback |
| 3 | Local Hy-MT2 models run through an external Python/uv backend process | Spawned processes inherit the sandbox; the backend, its venv, and HF caches live outside the container and die | Keep local translation via Apple's on-device **Translation framework** (`TranslationSession`, macOS 15+, free, sandbox-safe) as the MAS local provider; Python-backed Hy-MT2 stays direct-build-only. In-process MLX/llama.cpp is the long-term option if Hy-MT2 quality is required on MAS |
| 4 | No sandbox at all (Developer ID + hardened runtime only) | `com.apple.security.app-sandbox` entitlement is mandatory, on the main app and every nested binary (Tauri helper included) | New entitlements files + `build-mas.zsh` signing path |
| 5 | `KeyboardCaretLocator` positions the toast at the text caret via `AXUIElement` | Accessibility APIs are blocked under App Sandbox, full stop (DTS) | MAS build skips caret anchoring and falls back to the existing `toastPosition` setting (bottom-right etc.) |

Already MAS-compatible, no change needed:

- `Shift+Cmd+2` hotkey — Carbon `RegisterEventHotKey` works sandboxed.
- Screenshot translation — ScreenCaptureKit works sandboxed behind the Screen
  Recording permission prompt.
- OpenRouter networking — just needs the `network.client` entitlement.
- GitHub star prompt — `GitHubStarPromptPolicy` already detects the MAS
  receipt/sandbox and disables itself.
- LSUIElement menu-bar-only apps are allowed on MAS (review notes must tell
  the reviewer where the UI lives).

## 1. Accounts, certificates, identifiers

Apple Developer Program membership already exists (Developer ID signing runs
in CI). Additionally needed, all from the same account:

1. **Certificates** (Xcode → Settings → Accounts, or developer.apple.com):
   - `Apple Distribution` — signs the .app for MAS.
   - `Mac Installer Distribution` — signs the .pkg uploaded to App Store
     Connect. Neither exists in the current keychain/CI; Developer ID certs
     cannot be reused for MAS.
2. **App ID**: register `as.kargn.cctrans` explicitly (and
   `as.kargn.cctrans.helper` for the nested helper) with the App Sandbox
   capability.
3. **Provisioning profile**: type "Mac App Store", tied to the App ID and the
   Apple Distribution cert. Must be embedded as
   `Contents/embedded.provisionprofile` — direct distribution never needed
   this, so `build-app.zsh` has no support for it today.
4. **App Store Connect**: create the app record on bundle id
   `as.kargn.cctrans`. The name "CCTrans" must be unique store-wide.

## 2. Sandbox entitlements

Main app (`scripts/mas/CCTrans.entitlements`, new):

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
```

Notes:

- CCTrans Cloud uses signed StoreKit AppTransaction JWS on native macOS App
  Store builds. ASC rejects `com.apple.developer.devicecheck.appattest-environment`
  on macOS uploads, so do not add App Attest to the MAS entitlements. Local
  unsigned MAS-dev builds cannot impersonate an App Store-signed install by
  signing into an Apple ID; use `CCTRANS_DEV_TOKEN` for local QA.
- Screen Recording and Notifications are TCC prompts, not entitlements;
  nothing to declare beyond using the APIs.
- No file-access entitlements needed: settings, logs, and overrides under
  Application Support move into the sandbox container automatically
  (`~/Library/Containers/as.kargn.cctrans/...`). First MAS launch starts with
  fresh settings — acceptable, no migration planned.
- Tauri helper gets its own copy of the same two entitlements. It is launched
  via `NSWorkspace` as a separate app, so it cannot use
  `com.apple.security.inherit`; it must be a fully sandboxed app itself.
  Tauri 2 documents this path officially:
  <https://v2.tauri.app/distribute/app-store/> — note it additionally requires
  `com.apple.application-identifier` (TEAMID.bundle-id) and
  `com.apple.developer.team-identifier` keys in the MAS entitlements, matching
  the embedded provisioning profile.
- The WKWebView/Tauri runtime may additionally need
  `com.apple.security.files.user-selected.read-only` only if a file picker is
  ever exposed; today it is not.

## 3. Code changes (behind a `MAS_BUILD` compile flag)

`swift build -Xswiftc -DMAS_BUILD` plus `#if !MAS_BUILD` around:

1. **Sparkle**: `SPUStandardUpdaterController`, the "Check for Updates..."
   menu item, and the `Sparkle` import in `AppDelegate`. SwiftPM still links
   the package; the framework simply must not be embedded or referenced at
   runtime in the MAS bundle (build script omits `Sparkle.framework` and the
   `SUFeedURL`/`SUPublicEDKey` Info.plist keys).
2. **KeyboardMonitor → CGEventTap port** (not MAS-specific; do it for both
   builds): replace `NSEvent.addGlobalMonitorForEvents(.keyDown)` with a
   listen-only `CGEventTap`. Quinn (Apple DTS): "you need to use an API that
   relies on … Input Monitoring rather than … Accessibility. That means
   `CGEventTap` rather than the `NSEvent` monitor" — and that combination is
   explicitly fine in a sandboxed app. `PasteboardMonitor`'s
   same-text-copied-twice detection (already implemented and tested) remains
   the fallback when the user declines Input Monitoring.
3. **Local model provider**: in the MAS build, swap the Python-backed
   `localHyMT2` provider for Apple's Translation framework
   (`TranslationSession`). Session acquisition is SwiftUI-only, so host an
   offscreen `NSHostingView` carrying the `.translationTask` modifier from the
   keep-alive window. Language-pack downloads are one-time, Apple-managed, and
   on-device. Hy-MT2 stays a direct-build feature; revisit in-process
   MLX-swift (weights download = data, allowed; spawning external binaries =
   what actually breaks) only if Hy-MT2 parity on MAS becomes worth it.
4. **KeyboardCaretLocator**: `#if MAS_BUILD` skip — `AXUIElement` is blocked
   under the sandbox. Toast placement falls back to the `toastPosition`
   user setting.
5. **Permission helper**: Accessibility section does not apply; Input
   Monitoring (for the event tap) and Screen Recording remain.
6. **App Group launch channel** (discovered during pre-submission QA,
   2026-06-12): two sandbox walls silently broke every Tauri surface in the
   MAS build —
   - `NSWorkspace.OpenConfiguration.arguments` is ignored when the caller is
     sandboxed, so the helper booted with empty argv: no surface flag, no
     `--app-variant mas`. The persistent toast process degraded into a bare
     settings window showing direct-build providers.
   - The app and the helper have different bundle ids, hence different
     sandbox containers; `~/Library/Application Support` is not shared, so
     toast payloads, settings, and request logs never crossed processes.

   Fix: both sides use the team-prefixed App Group
   `6YQH3QFFK8.as.kargn.cctrans` (no portal registration or profile entry
   needed for team-prefixed groups on macOS). The Swift shell writes each
   launch as a one-shot `helper-launches/pending-*.json`; the helper claims
   it by atomic rename and treats the stored arguments as argv
   (`effective_args()` in `src-tauri/src/lib.rs`). The claimed file is also a
   lease and pid registry: deleting it asks the persistent toast to exit
   (sandboxed apps cannot pkill), and a bare sandboxed boot with nothing to
   claim exits instead of showing a ghost settings window. Local QA of the
   sandboxed bundle must be signed with a real team identity (e.g. Developer
   ID); ad-hoc signing makes macOS 15 prompt "access data from other apps"
   on every group-container file access, and re-signing in place requires
   deleting `~/Library/Containers/as.kargn.cctrans*` (container identity is
   bound to the code signature). This same code-signature/container binding is
   why the App Store reviewer saw the "CCTrans differs from previously opened
   versions" dialog on a machine that had already run an earlier review build.
7. **CLI fork-exec sandbox trap** (discovered post-rejection, 2026-06-18):
   the Tauri helper (`cctrans-tauri`, itself sandboxed) fork-execs the main
   `CCTrans` Swift binary for retranslation, local-model benchmarks, and
   login-item changes (`Command::new(legacy_binary_path(..))` in
   `src-tauri/src/lib.rs`). Because that binary carries its own
   `com.apple.security.app-sandbox`, the child re-initializes its own sandbox
   container at launch and traps in `_libsecinit_appsandbox`
   (`EXC_BREAKPOINT`/`SIGTRAP`, before `main()`). Invisible in dev builds
   (unsandboxed); this is what crashed 0.3.2 on review (Guideline 2.1 App
   Completeness, "crashed on launch"). It is the opposite of the Python backend
   (item 3): a binary with NO sandbox entitlement implicitly inherits the
   parent's sandbox, but a binary WITH the entitlement must not be fork-exec'd
   by a sandboxed parent.

   Fix: `build-mas.zsh` bundles `cctrans-cli`, a byte-for-byte copy of the main
   binary signed with `com.apple.security.app-sandbox` +
   `com.apple.security.inherit` only (`scripts/mas/cctrans-cli.entitlements`),
   next to `cctrans-tauri`. `legacy_binary_path()` prefers that sibling, so the
   helper spawns an inherited-sandbox copy that runs inside the helper's own
   sandbox (App Group + `network.client` included) without re-init. Unlike the
   NSWorkspace-launched helper — which cannot inherit and must be a full
   sandboxed app — a fork-exec'd child can and must inherit.

   **Login-item exception** (fixed 2026-06-19): `cctrans-cli` lives *inside*
   `CCTransTauri.app/Contents/MacOS/`, so its `Bundle.main` resolves to the
   inner helper (`as.kargn.cctrans.helper`), not the outer `CCTrans.app`
   (`as.kargn.cctrans`). Retranslation and benchmarks don't care — they never
   read `Bundle.main`. But `SMAppService.mainApp` registers `Bundle.main`, so
   running `--set-launch-at-login` through `cctrans-cli` registered the **inner
   helper** as the login item ("CCTransTauri will open at login" instead of
   "CCTrans"). Login is the one command that must run where `Bundle.main` is the
   outer app. Fix: the sandboxed toast no longer spawns `cctrans-cli` for login;
   it writes a request into the shared App Group dir (`login-requests/req-*.json`,
   atomic temp+rename) and the resident outer Swift host serves it via
   `SMAppService` and writes back `resp-<nonce>.json` (`AppDelegate.serveLoginRequests`
   ↔ `request_login_item()` in `src-tauri/src/lib.rs`). `cctrans-cli` stays for
   retranslation/benchmarks; only login moved off it. Off-MAS the CLI path is
   unchanged (it already resolves the outer binary, so `Bundle.main` is correct).

## 4. Build + package pipeline (`scripts/build-mas.zsh`, new)

Mirror `build-app.zsh`, with these differences:

1. `swift build -c release -Xswiftc -DMAS_BUILD`.
2. No Sparkle embedding, no rpath for it, no feed keys in Info.plist.
3. Embed the Mac App Store provisioning profile at
   `Contents/embedded.provisionprofile` (helper app gets its own).
4. Sign inside-out with `Apple Distribution`, passing the entitlements file at
   every `codesign` call (helper first, then the outer app). Hardened runtime
   is a Developer ID concept; for MAS the sandbox entitlement is what matters.
5. Build the installer package:

   ```sh
   productbuild --component dist-mas/CCTrans.app /Applications \
     --sign "3rd Party Mac Developer Installer: <name> (<team>)" \
     dist-mas/CCTrans.pkg
   ```

6. Validate locally before upload:

  ```sh
  codesign -dvv --entitlements - dist-mas/CCTrans.app   # sandbox + app group on main app
  xcrun stapler validate ...   # not needed: MAS pkgs are NOT notarized
  ```

   MAS uploads skip notarization entirely; App Review replaces it.

## 5. Upload and review

1. Upload the .pkg with the **Transporter** app, or in CI with
   `xcrun altool --upload-package` using an App Store Connect API key
   (`--upload-app` still works but is deprecated; `notarytool` is for
   Developer ID notarization and plays no role here). `fastlane deliver` /
   the App Store Connect API are equivalent automation routes.
2. App Store Connect metadata:
   - Screenshots: 1280×800 / 1440×900 / 2560×1600 / 2880×1800 only.
   - Privacy policy URL (required) + privacy "nutrition label". CCTrans
     stores the OpenRouter key locally and sends translated text to
     OpenRouter — declare "data not collected by the developer" only if that
     stays true; otherwise declare third-party processing.
   - Category (Productivity or Utilities), free pricing, export compliance
     (uses only standard HTTPS → exempt).
3. **Review notes are critical** for this app:
   - It is LSUIElement: tell the reviewer the app lives in the menu bar and
     how to trigger a translation (copy the same text twice).
   - Explain the Screen Recording prompt (screenshot translation) — missing
     justification is a common 2.5.x rejection.
   - Provide a throwaway OpenRouter API key for the reviewer, or a demo mode;
     a translator that does nothing without a paid key risks a 2.1 "minimum
     functionality" rejection. **Decide before submission.**
4. TestFlight for macOS works for beta builds from the same .pkg pipeline if
   a staged rollout is wanted.

## 6. Known review risks

| Guideline | Risk | Mitigation |
|---|---|---|
| 2.4.5 App Sandbox | Any nested binary without the sandbox entitlement fails ingest automatically | Entitlements on app + helper + every executable |
| 2.5.2 downloaded code | Python local-model runtime downloads and runs code | Python path excluded from MAS build; Translation framework models are Apple-managed |
| 2.1 minimum functionality | App is inert without an API key | Translation framework provider works with zero setup; reviewer demo key for OpenRouter features in review notes |
| 5.1.1 permission purpose | Input Monitoring + Screen Recording without clear reason | Purpose explained in-app before prompting + review notes; app stays functional (pasteboard fallback) if denied |
| 4.x design / discoverability | Menu-bar-only app "looks broken" | Review notes + first-launch onboarding window already exists |

## 7. Open decisions before any submission

1. MAS v1 feature set: Cmd+C double-press (CGEventTap) + Apple Translation
   framework local provider + OpenRouter + screenshot translation, minus
   Hy-MT2 and caret-anchored toasts. Confirm this cut.
2. Free, or paid/IAP? (Free assumed throughout this plan.)
3. Reviewer access: demo key vs. limited built-in demo quota (less pressing
   now that the Translation provider works without any key).
4. Whether the MAS variant is worth maintaining at all next to the
   self-updating direct build — every release doubles QA surface.
5. Whether the direct build also moves to CGEventTap + Translation framework
   (shrinks the build-flag delta and the QA matrix).

## 8. Research notes (2026-06)

- Sandbox + keyboard: Quinn (Apple DTS) — Accessibility APIs are blocked
  under App Sandbox, but `CGEventTap` behind Input Monitoring works, MAS
  included: <https://developer.apple.com/forums/thread/789896>.
- Translation framework (`TranslationSession`, on-device, free):
  <https://developer.apple.com/documentation/translation/translationsession>,
  intro: <https://developer.apple.com/videos/play/wwdc2024/10117/>. SwiftUI
  session acquisition caveat:
  <https://www.polpiella.dev/swift-translation-api/>.
- Foundation Models (macOS 26+) is **not** a translation API — usable later
  for auxiliary features only:
  <https://developer.apple.com/documentation/FoundationModels>.
- On-device LLM precedent for MAS: in-process inference (mlx-swift /
  embedded llama.cpp) is the viable shape; spawning external binaries or
  daemons is what breaks sandboxing (macMLX case, LocalLLMClient):
  <https://github.com/ml-explore/mlx-swift>.
- Tauri 2 official MAS guide (entitlements, provisioning, productbuild,
  upload): <https://v2.tauri.app/distribute/app-store/>.
