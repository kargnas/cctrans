---
name: testflight-release
description: >-
  Cuts a Mac App Store / TestFlight release for the CCTrans macOS app (App ID
  6779669255, bundle as.kargn.cctrans) by dispatching the "Mac App Store
  Release" GitHub Actions workflow (release-mas.yml): build the sandboxed
  variant, sign with Apple Distribution, productbuild a .pkg, and upload to App
  Store Connect with altool. The skill picks the marketing version and unique
  CFBundleVersion, dispatches on origin/main, watches the run to success, and
  verifies the build reached App Store Connect / TestFlight processing. Use when
  asked to release to TestFlight, ship a new MAS build, 테스트플라이트 릴리즈,
  새 빌드 올려, cut a release, or resubmit a build after an App Review rejection.
metadata:
  refs:
    workflow: ".github/workflows/release-mas.yml (workflow name: \"Mac App Store Release\")"
    app: "App Store Connect App ID 6779669255, bundle as.kargn.cctrans, team 520806"
---

# TestFlight / Mac App Store release

Ships a new CCTrans build to App Store Connect (which feeds TestFlight and App
Review) by dispatching a GitHub Actions workflow. The build, signing, and upload
run **in CI** using repo secrets — nothing builds or signs on the local Mac.

## When to use

"Release to TestFlight", "ship a new MAS build", "cut 0.3.x", "올려/릴리즈",
"resubmit after the rejection". For *checking* an existing build's review verdict
instead, use the **appstore-review-status** skill.

## How it works (and why)

CI is the source of truth: `gh workflow run` dispatches the **Mac App Store
Release** workflow (.github/workflows/release-mas.yml) on a branch ref, the job
runs `actions/checkout` on that ref, builds with
`scripts/build-mas.zsh`, and uploads with `xcrun altool`. So the **commit you
release is whatever is on `origin/<ref>` at dispatch time** — local commits that
are not pushed are NOT built. Always push first.

## Step 1 — Pre-flight (MUST verify before dispatch)

1. The change to ship is committed AND pushed to the ref you will release
   (normally `main`):
   ```bash
   git rev-parse --short HEAD origin/main   # the two SHAs must match
   git status --porcelain                   # expect empty (nothing uncommitted)
   ```
   If `HEAD` is ahead of `origin/main`, `git push origin main` first. If a
   parallel agent (Codex) shares the checkout, isolate + fast-forward merge per
   the worktree-isolation rule before pushing.
2. `gh auth status` shows a logged-in account with repo access.

VERIFY: do not proceed until local `main` == `origin/main` and the tree is clean.

## Step 2 — Choose version + build number

The workflow takes two inputs:

| Input | Required | Meaning |
|-------|----------|---------|
| `version` | yes | Marketing version, e.g. `0.3.5` (no leading `v`). |
| `build_number` | no | Unique `CFBundleVersion`. Defaults to `version`. |

Rules (App Store Connect rejects a duplicate `CFBundleVersion`):

- **New work / normal release** → bump the marketing version (`0.3.4` → `0.3.5`)
  and let `build_number` default to it.
- **Resubmit the SAME version after a rejection** → keep `version` and pass a
  higher, unique `build_number` (e.g. `version=0.3.4`, `build_number=0.3.4.1`).
- When unsure whether a number was used, list recent runs (Step 4) or check the
  TestFlight section of the **appstore-review-status** skill — every prior
  `version` shown there is already taken.

Confirm the chosen `version` with the user when it is ambiguous; uploading is
outward-facing and consumes a build number.

## Step 3 — Dispatch

```bash
gh workflow run "Mac App Store Release" --ref main \
  -f version=0.3.5
# resubmit form:
# gh workflow run "Mac App Store Release" --ref main -f version=0.3.4 -f build_number=0.3.4.1
```

## Step 4 — Watch the run to completion

```bash
sleep 6                                              # let the run register
RUN=$(gh run list --workflow="Mac App Store Release" --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --exit-status                    # exits non-zero if the run fails
```

A green run took ~3–4 min historically. If `gh run watch` exits non-zero, open
the failing step's log (`gh run view "$RUN" --log-failed`) and fix before
re-dispatching — common failures are the unique-build-number reject at the
altool step and a missing signing secret.

## Step 5 — Verify it landed

`altool` success means App Store Connect accepted the upload; the build then
**processes** for a few minutes to ~30 min before it is selectable in TestFlight
/ for submission. Confirm processing/availability with the sibling skill:

```bash
.claude/skills/appstore-review-status/scripts/asc-review.zsh   # TestFlight builds section
```

Report to the user: the run URL/result, the version+build uploaded, and that the
build is processing (not yet live). Submitting it for App Review is the next step
(Step 6) — uploading alone does NOT submit.

## Step 6 — Submit for App Review (and the resubmit blocker)

Steps 1–5 only UPLOAD the build; they do not submit it. To put a version into the
review queue, attach the build to the App Store version and **Submit**. Two ways:

- **ASC web** (most reliable, ~3 clicks): the distribution page →
  `https://appstoreconnect.apple.com/apps/6779669255/distribution` → open the
  version → Submit for Review. The web uses a different Apple backend than the
  public API, so it works even when the API path below 500s.
- **Automated** via `fastlane deliver`, run **locally** with the spaceship cookie
  session (the same one appstore-review-status uses). The CI `deliver.yml`
  (`submit_for_review=true`) CANNOT do a post-rejection resubmit — see the blocker.

### The post-rejection blocker (this WILL bite — cost ~8 failed tries to learn)

After a rejection the previous review submission stays **open** as
`state=UNRESOLVED_ISSUES` (visible in appstore-review-status) and BLOCKS a new
submission:

- The api_key path (CI `deliver.yml`) fails the submit step with a misleading
  `The request could not be completed because: Server error got 500` — the build
  *selects* fine, then the submit 500s. It is **not** an Apple outage; retrying
  the identical path just 500s again.
- The cookie path says it plainly: `Cannot submit for review - A review
  submission is already in progress`.

`deliver.yml` can't clear it (it has no `reject_if_possible`). Fix it locally with
the cookie session — two runs:

```bash
cd <cctrans-store repo root>      # deliver reads fastlane/ there (metadata repo)
common=(--username kars@kargn.as --app_identifier as.kargn.cctrans --platform osx \
        --app_version <v> --build_number <v> --skip_metadata true \
        --skip_screenshots true --skip_binary_upload true --force true \
        --run_precheck_before_submit false)
env FASTLANE_USER=kars@kargn.as FASTLANE_ITC_TEAM_ID=520806 \
    SPACESHIP_SKIP_2FA_UPGRADE=1 FASTLANE_SKIP_UPDATE_CHECK=1 \
  fastlane deliver --submit_for_review true --reject_if_possible true "${common[@]}" < /dev/null
# ^ closes the stale UNRESOLVED_ISSUES submission (→ COMPLETE) and opens a fresh
#   one; it may then ERROR on post_review_submission_item — that's expected.
#   Run the SAME thing again WITHOUT --reject_if_possible; it now submits:
env FASTLANE_USER=kars@kargn.as FASTLANE_ITC_TEAM_ID=520806 \
    SPACESHIP_SKIP_2FA_UPGRADE=1 FASTLANE_SKIP_UPDATE_CHECK=1 \
  fastlane deliver --submit_for_review true "${common[@]}" < /dev/null
# expect: "Successfully submitted the app for review!"
```

If the cookie is stale (`Available session is not valid anymore`), run
`fastlane spaceauth -u kars@kargn.as` once (2FA) and retry.

VERIFY: appstore-review-status must show the version `state=WAITING_FOR_REVIEW`
AND a new review submission `state=WAITING_FOR_REVIEW`. Any other state = not
submitted; do not report success.

## Testers & first-time TestFlight setup

Internal testers with "access to all builds" receive each new processed build
automatically — no per-build action. For the one-time internal-group + tester
setup (and the spaceship gotchas that bite there), see
[guides/testflight-testers.md](guides/testflight-testers.md).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| altool: *bundle version … already exists* | `CFBundleVersion` was used. Re-dispatch with a higher unique `build_number`. |
| Run builds an old commit | You released a ref whose `origin` tip lacks your commit. Push, then re-dispatch. |
| Signing / profile step fails | A `CCTRANS_MAS_*` / `APPLE_TEAM_ID` repo secret is missing or expired (see the secret list at the top of the workflow file, .github/workflows/release-mas.yml). |
| `gh workflow run` 404 | Wrong workflow name; it is exactly `Mac App Store Release`. |
| Submit step: `Server error got 500` (build selects, then 500s) — repeats every retry | NOT an outage. A stale `UNRESOLVED_ISSUES` review submission is blocking it. Clear locally with `deliver --reject_if_possible true`, then resubmit (Step 6). |
| `Cannot submit for review - A review submission is already in progress` | Same blocker, seen on the cookie path. Run `--reject_if_possible true` once, then plain `--submit_for_review true` (Step 6). |
