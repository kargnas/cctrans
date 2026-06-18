# CCTrans Agent Guide

## Mission

CCTrans is a macOS menu-bar translator. Keep the app native-feeling, fast, and operationally clear. Preserve existing translation behavior while migrating UI surfaces to Tauri 2 + Rust + Svelte.

## Project Shape

- SwiftPM app remains the macOS menu-bar shell until the Tauri shell fully replaces it.
- Bundle identifier must stay `as.kargn.cctrans`.
- macOS target: macOS 15+, Swift 6.2 tools.
- Tauri surfaces are the product UI layer. Do not add new AppKit auxiliary windows.
- Keep secrets out of Git. Never commit `.env.local`, token caches, or credential-bearing logs.

## Layout

- `Sources/CCTransCore/`: platform-light translation logic, settings defaults, model registry, language handling.
- `Sources/CCTrans/`: macOS shell, menu bar app, monitors, and platform adapters.
- `Tests/CCTransTests/`: Swift tests.
- `scripts/`: build/install/package helpers and local model runtimes.
- `src/`: Svelte settings UI for the Tauri migration.
- `src-tauri/`: Rust/Tauri backend and app configuration.
- `design/`: visual reference board. Treat it as required input for UI work.
- `DESIGN.md`: durable design contract. Update it when design decisions change.

## Commands

```sh
swift test
swift build
./scripts/run-dev.zsh --show-settings
./scripts/build-mas.zsh
npm install
npm run check
npm run build
npm run tauri dev
cd src-tauri && cargo test
```

`build-mas.zsh` produces the sandboxed Mac App Store variant in `dist-mas/`
(plan and signing env vars: `docs/mac-app-store.md`). It builds with
`CCTRANS_MAS_BUILD=1` in the separate `.build-mas` scratch path so the
Sparkle-free manifest never pollutes the normal `.build` cache.

VS Code's `🚀 Run Dev App Bundle` launch configuration runs:

```sh
./scripts/run-dev.zsh
```

After completed development or documentation work is verified and committed, run this launch path before reporting completion so the user's currently running `dist/CCTrans.app` is replaced with the latest build.

## Release And Auto Update

- Sparkle 2 (SPM) drives auto update. `scripts/build-app.zsh` embeds `Sparkle.framework`, adds the `@executable_path/../Frameworks` rpath, and injects `SUFeedURL`/`SUPublicEDKey` plus `CCTRANS_VERSION` into Info.plist.
- Pushing a `v*` tag runs `.github/workflows/build-release.yml`: build → Developer ID sign (hardened runtime, inside-out, no ad-hoc fallback) → notarize app and DMG → Sparkle-sign DMG → publish DMG + `appcast.xml` to GitHub Releases.
- Code pushes to `main` auto-release via `.github/workflows/auto-release.yml`: 10-minute cooldown (newer push cancels and restarts), patch bump from the latest tag, then dispatches `build-release.yml`. `[skip release]` in the head commit message opts out; manual dispatch chooses patch/minor/major.
- The Sparkle EdDSA private key lives in the login keychain (account `CCTrans`) and as the `SPARKLE_PRIVATE_KEY` repo secret. Never commit it. The release tag version must exceed the last released version.
- After publishing, the `update-tap` job in `build-release.yml` bumps `Casks/cctrans.rb` (version + sha256 only) in [kargnas/homebrew-tap](https://github.com/kargnas/homebrew-tap) over a write deploy key stored as the `TAP_SSH_KEY` secret. The cask structure itself is owned by the tap repo; edit it there.
- Dev runs outside an `.app` bundle skip updater startup on purpose (`startUpdaterIfBundled`).

## Defaults And Behavior

- Default UI language: English.
- Default translation target: Korean.
- Default translation model: app-recommended local Hugging Face Hy-MT2.
- The `appleTranslation` provider uses Apple's on-device Translation framework
  through `AppleTranslationHost` (SwiftUI session host in the keep-alive
  window). It is the only local provider in the MAS variant; the direct build
  offers it alongside Hy-MT2.
- OpenRouter handles non-local LLM translation and screenshot translation.
- Preserve `Cmd+C` double press and `Shift+Cmd+2` shortcuts.
- Every persisted setting is code-default plus user override:
  - persist only values different from `TranslatorSettings()`;
  - show reset control only when an override exists;
  - remove the stored override when value returns to default;
  - remove the full settings store when all values equal defaults.
- GitHub star ask (`GitHubStarPrompter` + `GitHubStarPromptPolicy`) runs once per machine, only on standalone installs (brew cask / DMG / install-app.zsh copies), only after initial setup, and only when an authenticated `gh` CLI reports the repo unstarred. Mac App Store and workspace/dev builds never prompt; `scripts/install-app.zsh` pre-marks the `githubStarPromptHandled` default after its own terminal ask. Headless check: `--github-star-smoke`.

## Translation Toast Contract

- Translation toast glass stays visually stable: do not animate or vary whole-bubble opacity, background alpha, blur, or hover translucency during countdown, hover, or mouse-out. Progress belongs in the countdown bar only.
- After a result or error appears, auto-dismiss countdown starts immediately.
- Hovering the toast resets the countdown to the full duration and pauses it; leaving the toast starts counting down from that reset duration.
- Any click outside the visible toast closes/hides it immediately, including during loading.
- A loading-to-result update must show the toast again for the same request sequence, so a cold local model warmup cannot finish ready while silently skipping the translated result.
- Rust owns global pointer hit-testing for the non-activating toast and emits `toast-hover` plus `toast-dismiss-request`; Svelte owns timer state and close decisions.

## Settings Contract

The settings UI must cover current AppKit behavior before adding new behavior:

- Translation Model: one model-first selector that groups `Local Model` and `OpenRouter LLM` choices. Selecting any model must also select the matching provider.
- Every model selector must include a `Default` option that resolves to the app-recommended model for that provider.
- Source Language: `Auto` plus supported language list.
- Target Language: supported language list without `Auto`.
- Toast Position: bottom/top and left/right variants.
- Models tab: manage favorite local and OpenRouter models.
- Local Model: all built-in models plus custom models when supported.
- Local Backend Path: blank means automatic backend selection.
- Custom Models JSON: blank means default config lookup.
- OpenRouter Text Model and Vision Model: show popular models, pricing, free status, and modality support.
- OpenRouter API Key: settings may save or clear `OPENROUTER_API_KEY` in `~/.config/cctrans/.env`; never expose the stored key value back to the UI.
- Permission status for keyboard and screen recording.
- Diagnostics/actions: model setup, permission panes, text test, screenshot translation, request logs, stacked toast preview.

Do not edit other credentials in the settings UI. `CredentialsProvider` owns `.env.local`, app-adjacent env files, and `~/.config/cctrans/.env`.

## Platform And Surface Rules

- Treat Tauri/Rust/Svelte as the shared UI architecture for macOS and future Windows support.
- Define every app window as a named Tauri surface with stable label, route, title, size, and behavior. Keep this registry in Rust so macOS and Windows use the same contract.
- Keep app state in shared app-data JSON files with code-default plus override semantics. Swift shell code may read/write that shared state, but should not introduce a second settings source such as a new `UserDefaults` key.
- Use platform adapters only for OS capabilities: global keyboard monitoring, screenshot capture, privacy/settings URLs, app activation, packaging, and shell integration.
- For cross-platform actions, route through small Rust helpers that branch on `target_os` instead of embedding macOS-only command strings in Svelte.
- Do not create or resurrect AppKit helper windows for settings, local model setup, request logs, permission helper, or diagnostics previews. These belong in Tauri surfaces.
- If a capability is macOS-only today, expose it through the shared Tauri action/status contract and return an explicit unsupported state on Windows until the Windows adapter exists.
- Keep visual styling platform-neutral except where native chrome owns it. Window title bars, shadows, privacy panes, and OS prompts are platform-owned.

## Design Rules

- Before building or restructuring a screen, create a visual mockup with Codex image generation.
- Follow `DESIGN.md` and `design/` for color, spacing, typography, sidebar/grouped-row layout, and component behavior.
- Do not fake platform-owned features in web/CSS:
  - native titlebar/window controls come from Tauri/macOS;
  - native window shadow comes from the OS;
  - System Settings privacy panes stay OS-owned.
- Use SF Pro system font stack and semantic macOS-like colors.
- Use the 4 / 8 / 12 / 16 / 20 / 24 spacing scale.
- Keep groups at 8px radius or less unless native platform chrome owns the shape.
- Avoid decorative gradients, orbs, stock imagery, and marketing layouts in app surfaces.
- Use icon buttons or icon+text buttons for concrete actions.

## Layout Rules

- Swift/AppKit code should stay shell-level. Do not build new settings or diagnostic screens there.
- Tauri/Svelte screens use stable grid/flex dimensions. Text must not overflow controls at minimum window size.
- Keep labels and controls scannable in two-column grouped rows.
- Keep minimum settings window size large enough to show controls without clipping.

## Verification

Before claiming UI work complete:

- Run targeted unit tests for changed behavior.
- Run Swift checks when Swift behavior changes.
- For local translation path changes, run `./scripts/ci/local-model-smoke.zsh <local-model-id>` against the built binary. CI (`.github/workflows/model-ci.yml`) runs the same script for bundled models on translation-path pushes/PRs and weekly.
- Run `npm run check`, `npm run build`, and `cd src-tauri && cargo test` for Tauri/Svelte/Rust changes.
- Run the UI, capture a screenshot, crop the implemented settings surface, and compare it against `design/image.png` plus the generated mockup/reference.
- Check generated CSS for forbidden custom platform shadows (`box-shadow`) in the settings shell.
- After committing completed work, run the VS Code `🚀 Run Dev App Bundle` equivalent (`./scripts/run-dev.zsh`) before the final report unless the user explicitly says not to relaunch.
- Report any verification gap clearly.

## Git Hygiene

- Worktree may be dirty. Do not revert user changes unless explicitly asked.
- Keep diffs small and reversible.
- Add dependencies only when required by the requested stack or by an existing project rule.
- After development work is implemented and verified, create the relevant git commit before reporting completion. Do not leave completed development work uncommitted unless the user explicitly asks not to commit or the worktree contains unresolved unrelated changes that make a safe commit impossible.
- Commit messages, when requested, must follow the Lore Commit Protocol from repo history/instructions.
