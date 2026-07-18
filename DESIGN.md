# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-06-01
- Primary product surfaces: macOS menu-bar translator, native onboarding wizard, Tauri translation popover, settings window, permission helper, local model setup, request logs.
- Evidence reviewed:
  - `design/image.png` and `design/guide.html`: component board for translation overlays, settings window, tokens, spacing, typography, color, radius, motion.
  - `Sources/CCTrans/SettingsWindowController.swift`: current AppKit settings behavior, groups, reset-to-default controls, diagnostics.
  - `Sources/CCTransCore/TranslatorSettings.swift`: code defaults, persistence keys, legacy decode, override-only encoding.
  - `Sources/CCTrans/SettingsStore.swift`: current UserDefaults key and "remove when all defaults" behavior.
  - `Sources/CCTrans/AppDelegate.swift`: menu settings actions, shortcuts, permissions, diagnostics flows.
  - `README.md`: user-facing feature set, permissions, run/test commands.

## Brand
- Personality: quiet, native, fast, utility-first, trustworthy.
- Trust signals: macOS-native window chrome, system font, explicit permission status, visible translation model state, reset controls only when an override exists.
- Avoid: marketing pages, decorative gradients/orbs, custom fake platform shadows, oversized hero layouts, hardcoded non-system UI language defaults.

## Product goals
- Goals: translate copied text quickly, translate screenshots, expose provider/language/model settings without hiding operational state.
- Non-goals: broad design-system experimentation, cloud-account management, replacing OS privacy panes, adding settings not backed by current product behavior.
- Success signals: settings changes persist as overrides only, default resets remove overrides, shortcuts remain `Cmd+C` twice and `Shift+Cmd+2`, translation popovers anchor near the keyboard caret/selection when Accessibility can report it, visual shell matches `design/` closely while relying on OS window chrome/shadow.

## Personas and jobs
- Primary personas: macOS power users, developers, bilingual readers, users comparing local and OpenRouter translation.
- User jobs: choose a translation model that also selects the provider, manage favorite/default models, set source/target languages, confirm permissions, run diagnostics, inspect last result/logs, recover defaults.
- Key contexts of use: menu-bar utility workflow, short text fragments, screenshots, development/debug sessions.

## Information architecture
- Primary navigation: macOS settings sidebar.
- Core routes/screens: General, Models, Shortcuts, Excluded Apps, Advanced, Info.
- Content hierarchy: high-frequency translation model/language settings first; model favorites, OpenRouter pricing/modality/API key configuration second; shortcut/permission status third; advanced paths and storage details last.

## Design principles
- Principle 1: Native first. Use OS titlebar, traffic-light controls, window shadow, keyboard permissions, and system settings links instead of drawing fake platform features.
- Principle 2: State must explain itself. Defaults, overrides, readiness, and last diagnostic result stay visible.
- Tradeoffs: complete settings coverage may require wider content than the `design/` board mock; keep the same sidebar/group-row language rather than forcing every control into one small panel.

## Visual language
- Color: `design/` light tokens: Apple blue `#007aff`, green `#34c759`, red `#ff3b30`, text `#1d1d1f`, secondary `#6e6e73`, borders `#e5e5ea` / `#d2d2d7`.
- Color scheme: all surfaces are tokenized in `src/app.css` and follow the system appearance via `prefers-color-scheme`. Light token values stay byte-identical to the `design/` board; a dark token set mirrors them for macOS dark mode. The transparent toast WebView cannot read `prefers-color-scheme` on its own, so Rust applies the system theme to it per popup.
- Accent: the solid accent follows the live macOS system accent (`AccentColor`) where the engine supports it, falling back to Apple blue `#007aff`. Accent tints derive from fixed `#007aff` via `color-mix` so they always resolve.
- Typography: SF Pro system stack through `-apple-system`, compact settings text, no negative letter spacing.
- Spacing/layout rhythm: 8px grid; 4 / 8 / 12 / 16 / 20 / 24 scale.
- Scroll edges: the settings content scroll area runs to the window bottom edge with no trailing gap, fade, or mask; scrolled content hard-clips at the edge exactly like macOS System Settings. End-of-scroll breathing room lives inside the scroll content (pane bottom padding), never below it.
- Scrollbar: the content column itself is the scroll container, so the scrollbar spans the full window height flush against the right window edge; it must never float inset beside padded content. The page header is sticky inside that scroll and gains System Settings-style material (blur + hairline) only while content is scrolled beneath it.
- Shape/radius/elevation: 6px sidebar rows and controls, 8px setting groups. Do not implement custom CSS window shadows; native Tauri/macOS window shadow owns settings windows. Translation popover shadow is component-level elevation from `design/`, while transparent borderless window support comes from macOS/Tauri.
- Material: the settings window uses native macOS vibrancy (Tauri `windowEffects` `sidebar` on the `main` window plus a transparent web root); content surfaces stay ~0.86 opaque so the material reads as a subtle backdrop without hurting legibility. The separate `translation` toast window stays fully transparent with no window-level or native material layer; only the rounded bubble applies CSS backdrop blur. The blur is re-armed on show/refresh because transparent WebKit surfaces can skip backdrop sampling on first paint.
- Motion: short state transitions only where needed; no decorative motion. Exception: the onboarding wizard's preview stage runs a looped ⌘+C C → toast simulation and spring step transitions — onboarding is a one-time teaching surface, so demonstrative motion is allowed there (and only there); it must pause under reduced motion.
- Imagery/iconography: use symbol-style icons for settings sidebar and action buttons; do not use stock imagery in app surfaces.

## Components
- Existing components to reuse: `TranslatorSettings`, `SettingsStore` semantics, `TranslationLanguage`, `LocalModelRegistry`, `OpenRouterModelCatalog`, current permission checks, diagnostics actions, and translation result behavior including loading/success/error states. Toast position is fallback only when the keyboard caret/selection bounds are unavailable.
- New/changed components: Tauri 2 settings shell, Svelte settings sidebar, grouped setting rows, model-first Translation Model selectors, favorite model rows, reset buttons, Rust settings command layer, Tauri/Svelte translation popover surface, native SwiftUI onboarding wizard (split layout: 3-step content column + dark preview stage; permission cards, provider card grid, in-window try-it step). The onboarding wizard stays native SwiftUI in the main app process because TCC permission requests must run in the process that taps the keyboard, and App Review 2.1 requires a main-process-owned window.
- Variants and states: default vs overridden setting rows, ready/not-granted permission states, saved/saving, success/error action notices, disabled reset buttons, translation loading/done/original/error states. Translation state switchers are debug-only and must not appear in the default popup.
- Token/component ownership: `design/guide.html` remains visual token reference; `src/app.css` owns Tauri web implementation tokens; Rust owns setting defaults and persistence normalization.

## Accessibility
- Target standard: keyboard navigable settings UI with native form controls and visible focus behavior.
- Keyboard/focus behavior: sidebar buttons, selects, inputs, reset buttons, and actions must be reachable by Tab and activate with Enter/Space. Esc and Cmd+W close the settings window (Esc first dismisses an open model menu); the window restores its last frame on reopen.
- Contrast/readability: text and border colors meet macOS contrast in both light and dark appearances; light values match `design/`, dark values mirror them. Status color is never the only signal.
- Screen-reader semantics: use real `button`, `select`, `input`, `label`, `aside`, `main`, and `aria-live` for notices.
- Reduced motion and sensory considerations: no required animation for comprehension.

## Responsive behavior
- Supported breakpoints/devices: macOS desktop windows, minimum 640 x 540 for the Tauri settings surface.
- Layout adaptations: sidebar remains fixed; setting rows collapse to one column below 700px preview width.
- Touch/hover differences: desktop pointer first; hover is supplementary only.

## Interaction states
- Loading: centered "Loading settings..." text.
- Empty: defaults load when no override store exists.
- Error: action notice plus last-result text where relevant.
- Success: saved status and success notice.
- Disabled: reset buttons remain visually reserved but inactive unless a setting differs from code default.
- Offline/slow network, if applicable: translation/model diagnostics surface command output rather than blocking settings edits.

## Content voice
- Tone: concise, operational, English by default.
- Terminology: "Translation Model", "Local Model", "OpenRouter LLM", "Models", "Favorite Models", "Default", "Source Language", "Target Language", "Toast Position", "Reset Defaults".
- Microcopy rules: use direct status labels like "Ready", "Not granted", "Saved"; avoid instructional paragraphs inside compact settings panes.

## Implementation constraints
- Framework/styling system: Tauri 2 + Rust backend + Svelte 5 frontend.
- Design-token constraints: follow `design/` colors, radii, grouped rows, sidebar navigation, and compact typography; do not use CSS `box-shadow` for platform-native window features.
- Performance constraints: load settings synchronously from small override JSON; avoid unnecessary model-catalog network calls in settings render. OpenRouter model pricing/modality metadata may use a static fallback catalog unless a live refresh is explicitly implemented.
- Compatibility constraints: macOS 15+, bundle identifier `as.kargn.cctrans`, default target language Korean, default translation model local Hy-MT2, OpenRouter for non-local and screenshot translation, Tauri `macos-private-api` enabled for transparent translation popover windows.
- Test/screenshot expectations: run build/check/tests; run UI, capture screenshot, crop settings and translation surfaces, compare against `design/image.png` references and generated mockup/reference.

## Open questions
- [ ] Full app-shell migration owner / impact: decide whether the AppKit menu-bar shell itself should remain native while user-facing helper and translation windows stay in Tauri.
- [ ] Storage compatibility owner / impact: decide whether Tauri production should read/write existing macOS UserDefaults binary `Data` key directly or keep the new JSON override store during migration.
