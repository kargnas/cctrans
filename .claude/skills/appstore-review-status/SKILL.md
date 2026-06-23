---
name: appstore-review-status
description: >-
  Fetches App Store Connect review status and full rejection details for the
  CCTrans macOS app (App ID 6779669255, bundle as.kargn.cctrans). Reports App
  Store version states, review-submission states, Resolution Center rejection
  messages, structured reviewRejection guideline codes (e.g. 2.1 App
  Completeness), and TestFlight build processing — by reusing the persisted
  fastlane spaceship Apple-ID web session (no ASC API key needed). Use when
  asked to check the Apple/App Store review result, 애플 심사결과, why a build was
  rejected, or a 반려 사유. Targets other apps via ASC_APP_ID / ASC_TEAM_ID.
metadata:
  env:
    ASC_USER: "optional — Apple ID for the spaceship web session (default kars@kargn.as)"
    ASC_APP_ID: "optional — App Store Connect app Apple ID (default 6779669255 = CCTrans)"
    ASC_TEAM_ID: "optional — App Store Connect team id (default 520806 = personal team)"
    FASTLANE_ITC_TEAM_ID: "optional — team id spaceship reads; wrapper sets it from ASC_TEAM_ID"
---

# App Store Connect review status

Pulls the current review verdict and rejection details for a macOS app from
App Store Connect. Built for **CCTrans** but works for any app the signed-in
Apple ID can see.

## How it works (and why this design)

Apple serves the **Resolution Center** data (rejection message text, attachment
references, `reviewRejections` guideline codes) **only to an Apple-ID web
session** — an ASC API `.p8` key gets `403`/empty for those endpoints. This repo
also keeps the API key's issuer id only as a CI secret, not on disk. So the
skill reuses the **persisted fastlane `spaceship` cookie** instead.

`spaceship` is not in the system ruby — it lives in Homebrew fastlane's private
gem home. `scripts/asc-review.zsh` injects that ruby + gem path, then runs
`scripts/asc_review.rb`.

## Run it

```bash
.claude/skills/appstore-review-status/scripts/asc-review.zsh
```

EXECUTE the wrapper (do not read `asc_review.rb` into context — it is a script,
not reference). It prints four sections: App Store versions, review submissions,
Resolution Center messages (HTML stripped to text) with guideline codes, and
TestFlight builds.

### Target a different app / account

```bash
ASC_APP_ID=1234567890 ASC_TEAM_ID=119657382 .claude/skills/appstore-review-status/scripts/asc-review.zsh
```

## Prerequisites

- Homebrew `fastlane` installed (`brew install fastlane`).
- A **valid persisted Apple-ID session** for `ASC_USER`. The session is created
  by `fastlane spaceauth` and stored at `~/.fastlane/spaceship/<user>/cookie`.
  It survives ~weeks, then needs a one-time refresh (2FA).

If login fails, the script prints the fix and exits non-zero:

```bash
fastlane spaceauth -u kars@kargn.as   # paste the 2FA code once
```

## Reading the output

| State (App Store version) | Meaning |
|---------------------------|---------|
| `PREPARE_FOR_SUBMISSION`  | Draft, not yet sent |
| `WAITING_FOR_REVIEW`      | In queue |
| `IN_REVIEW`               | Reviewer looking now |
| `REJECTED`                | Rejected — read the Resolution Center section |
| `PENDING_DEVELOPER_RELEASE` / `READY_FOR_SALE` | Approved |

Review-submission `state=UNRESOLVED_ISSUES` is the submission-level form of a
rejection; its thread holds the message(s). It also stays **open** and **blocks a
new submission** until cleared — a resubmit must reject it first (see the
**testflight-release** skill, "the post-rejection blocker").

## Attachments caveat (important)

When Apple writes "we have attached detailed crash logs", those files
(crash `.log`, screenshots) are **NOT retrievable through the API** — the
`resolutionCenterMessageAttachments` relationship only carries
developer-uploaded files and is empty for Apple's own attachments. The script
detects this and prints the web URL. Download the crash log / screenshot
manually from the Resolution Center:

```
https://appstoreconnect.apple.com/apps/<APP_ID>/distribution
```

Developer-uploaded attachments, when present, are printed inline with their
metadata.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Multiple teams found ... non-interactive` | Account is on >1 team. Set `ASC_TEAM_ID` to the team that owns the app (CCTrans = `520806`). |
| `LOGIN_FAILED ... session` | Cookie expired → `fastlane spaceauth -u <user>`. |
| `does not exist ... 'apps' with id` | Right session, wrong team — the app is not in `ASC_TEAM_ID`. Try the other team. |
| `Homebrew fastlane/ruby not found` | `brew install fastlane`, or edit the path globs in the wrapper. |
