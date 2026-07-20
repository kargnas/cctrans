# Onboarding Model Step — List-Row Redesign + OAuth Web Sign-in (Design)

Date: 2026-07-20
Status: approved by user (variant B, OAuth replaces all native auth)
Mockup: `docs/mockups/onboarding-model-step-variants.html` (variant B; follow-up panel now holds a single OAuth button instead of Apple/Email buttons)

## Problem

The onboarding wizard window is a fixed 760×520 canvas
(`OnboardingRootView.frame(width: 760, height: 520)`). On the model step, the
2×2 card grid (`ModelCardView`, `minHeight: 108`) plus the cloud account
follow-up panel (`CloudAccountFollowUp`, `minHeight: 210` with three vertically
stacked buttons) exceeds the 520 px height. The "Start Free Without an Account"
button and the status line render under the footer, and — because that clipped
button is what sets `accountState.canContinue` — **Next** stays disabled with
no visible way forward. The wizard is soft-locked on step 1 for CCTrans Cloud.

Second problem (found while auditing): "Start Free Without an Account" is shown
on ALL builds, but anonymous cloud translation requires a server-verifiable
device — MAS builds (AppTransaction / App Store receipt) or dev-token QA. On
direct/opensource builds with neither, `CctransManagedClient.translate` throws
`.attestUnavailable`. The button is dead UI there.

Third problem (raised by user): native in-window auth (email/password form,
native Sign in with Apple) cannot cover the real auth surface — kargn.as also
offers Google sign-in, and re-implementing every provider natively is not
viable. Auth must happen on the web.

## Decisions (all confirmed with user)

- Layout: **variant B — vertical list rows + radio**, replacing the 2×2
  `LazyVGrid` of cards. Chosen from 5 mockups.
- Auth: **remove ALL native auth UI from the app** (onboarding email form,
  onboarding Apple button, Tauri Settings email login/register, Rust
  `cctrans_account_email_login` / `cctrans_account_email_register` commands).
  Replaced by a single **"Sign in at kargn.as"** button that opens
  `ASWebAuthenticationSession` against the kargn.as OAuth page, which hosts
  Google / Apple / email sign-in itself.
- Token handoff: server redirects to the custom scheme
  `cctrans://auth/callback?token=...`; the app stores the token. (PKCE deferred
  — the app is a public client on the user's own machine; the threat model is
  the same as the current bearer-token-in-keychain model.)
- Anonymous button: **hidden via `#if MAS_BUILD`** on the choice panel. On
  direct builds the button does not exist (dead UI per `.attestUnavailable`).
- Window stays fixed 760×520; no resizable window, no step split.

## Design

### 1. Model list (replaces the card grid)

`ModelStepView`'s `LazyVGrid` becomes a vertical `VStack(spacing: 6)` of rows.
The `ModelOption` struct is unchanged (same
`provider/symbol/subtitle/badges/recommended` data).

Row layout (`ModelRowView`, replaces `ModelCardView`):

```
[radio] [SF Symbol 24px]  Title (bold, 13pt)  Subtitle (secondary, 11pt, same line)   [badges…]
```

- Height: content-sized (~34–38 px), no `minHeight`. 4 rows ≈ 150 px total
  (grid was ~230 px), freeing ~80 px.
- Selection: 16 px radio at the leading edge — `Color.secondary` ring
  unselected, accent-filled (border width 5) selected. Row stroke switches to
  accent, same as today's card.
- Badges right-aligned; subtitle truncates (`lineLimit(1)`), badges never
  truncate.
- Same background/border as today's card; same selection spring
  (`.spring(response: 0.3, dampingFraction: 0.8)`).
- MAS build still drops the Local Model row (existing `#if !MAS_BUILD` in
  `options` untouched).

### 2. Cloud account follow-up → single OAuth button

`CloudAccountFollowUp` shrinks to two states:

- **Signed out** (choice state): one prominent button
  "Sign in at kargn.as" (`arrow.up.forward.app` symbol) +
  `#if MAS_BUILD` "Start Free Without an Account" link button +
  status line. ~110 px tall. No email form, no Apple button, no segmented
  picker, no password field.
- **Signed in**: existing `signedInContent` unchanged (email, verification
  notice).

Behavior:

- Tap → `OnboardingFlowModel.signInWithOAuth()`:
  1. Build authorize URL: `https://kargn.as/auth/authorize?client=cctrans-macos&redirect_uri=cctrans://auth/callback` (exact path TBD with the server; the client passes only `redirect_uri` and a state nonce).
  2. `ASWebAuthenticationSession(url:, callbackURLScheme: "cctrans")` —
     `prefersEphemeralWebBrowserSession = false` so a returning user's kargn.as
     Safari cookies make Google/Apple one tap.
  3. On callback: parse `token` (and `state`, verified against the nonce) from
     the redirect URL, hand the token to the session store
     (`CctransAccountKeychainStore`), then fetch the account summary via the
     existing account client and call `accountState.succeed(account)`.
  4. On cancel (`ASWebAuthenticationSessionError.canceledLogin`): map to
     `accountState.fail(.cancelled)` — same as today's Apple cancel.
- Presentation anchor: the onboarding `NSWindow` (set on the session's
  `presentationContextProvider` in the window controller's `show`).
- The custom URL scheme `cctrans` is registered in the app's
  `Info.plist` (`CFBundleURLTypes`); the OAuth path is additionally handled in
  `application(_:open:)` as a safety net for the system-browser fallback, but
  the session's callback scheme is the primary path.

State model (`CctransOnboardingAccountState`) changes:

- Remove: `isShowingEmailForm`, `emailMode`, `email`, `password`,
  `EmailMode`, `EmailSubmission`, `showEmailForm`, `hideEmailForm`,
  `selectEmailMode`, `beginEmailSubmission`. (The `.validation` failure case
  goes away with the form.)
- Keep: `isAnonymous`, `isLoading`, `account`, `failure`,
  `continueAnonymously`, `beginAppleAuthentication` (renamed
  `beginOAuthAuthentication`), `succeed`, `fail`, `cancelAuthentication`.
- `canContinue` unchanged: `account != nil || isAnonymous`.

### 3. Deletions (full-removal policy — no deprecation shims)

Native app (Swift):

- `CctransAppleSignIn.swift` — deleted. OAuth covers Apple sign-in via the
  web page.
- `OnboardingFlowModel`: `submitEmailAccount`, `showEmailAccountForm`,
  `hideEmailAccountForm`, `selectEmailMode`, `signInWithApple`, `accountTask`
  email branches — deleted. `accountFailure` keeps the
  `.accountLinkRequired`/generic mapping for OAuth errors.
- `CctransAccountClient.login(email:password:)` and
  `.register(name:email:password:passwordConfirmation:)` — deleted (no
  remaining caller).
- OnboardingSteps.swift: `CloudAccountFollowUp`'s `emailContent`,
  `Field` enum, `FocusState`, `emailModeBinding`, `emailSubmitTitle` — deleted.

Tauri shell (Rust + frontend):

- `src-tauri/src/lib.rs`: `cctrans_account_email_login`,
  `cctrans_account_email_register` commands + their `/auth/login`,
  `/auth/register` HTTP calls + command registration — deleted.
- `src/lib/account.ts`: `loginCctransAccount`, `registerCctransAccount` —
  deleted.
- `src/components/AccountSettings.svelte`: email login/register forms —
  replaced with the same "Sign in at kargn.as" action. In the Tauri webview
  the button opens the system browser at the authorize URL with
  `redirect_uri=cctrans://auth/callback`; the main app (already running)
  receives the deep link, stores the session, and the helper picks it up via
  the shared-dir account store. (If that handoff proves fragile, the Settings
  button instead asks the main app to present the OAuth session — decided at
  implementation time by which is fewer moving parts.)

Server contract needed (kargn.as):

- `GET /auth/authorize?client=...&redirect_uri=cctrans://auth/callback&state=...`
  → renders provider chooser (Google/Apple/email), completes sign-in, then
  302s to `redirect_uri?token=<bearer>&state=<state>`.
- The existing bearer token then works against the current account endpoints
  (no server change needed beyond the authorize page + redirect).

### 4. Footer / scrolling

- `OnboardingLeftPane` structure unchanged: step indicator, scrolling step
  body, fixed footer outside the `ScrollView` — Back/Next always visible.
- No window-size changes.

## Error handling

- OAuth network failure / non-token redirect →
  `accountState.fail(.request("Sign-in failed. Try again."))`, rendered by the
  existing status line.
- `state` mismatch → treat as failure, never store the token.
- Cancel → `.cancelled`, quiet status line (existing behavior).
- `.attestUnavailable` unchanged for direct-build anonymous attempts (button
  now hidden there, so only the dev-token path can hit it).

## Testing

1. Direct build, fresh state: wizard opens on step 1; all four rows visible;
   select CCTrans Cloud → follow-up fully inside window; **no** anonymous
   button, **no** email form, **no** Apple button; single "Sign in at
   kargn.as" button; Next disabled until OAuth succeeds.
2. OAuth happy path (signed MAS or dev build): button opens
   `ASWebAuthenticationSession` at kargn.as; complete Google sign-in; sheet
   closes; account email appears; Next enabled.
3. Cancel path: close the sheet → status returns to idle, no error banner,
   Next still disabled.
4. MAS build: anonymous button present; Local Model row absent.
5. Tauri Settings: no email/password fields remain; "Sign in at kargn.as"
   produces a signed-in account in the helper.
6. `grep -r "cctrans_account_email_login\|loginCctransAccount\|CctransAppleSignIn"`
   returns nothing after the change.

## Out of scope

- PKCE upgrade (follow-up hardening; needs server support anyway).
- Moving account creation out of onboarding entirely (variant E) — rejected.
- Purchase/restore flows — unchanged.
