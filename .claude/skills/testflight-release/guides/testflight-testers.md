# TestFlight internal testers (one-time setup)

Read this only when a build uploaded fine but **no one can install it from
TestFlight**, or when first wiring up internal testing. Day-to-day releases need
nothing here: an internal tester whose group has *access to all builds* gets
every newly processed build automatically.

## Auth

Same Apple-ID web session the `appstore-review-status` skill uses (an ASC API
`.p8` key is NOT enough for these writes). The session lives at
`~/.fastlane/spaceship/<user>/cookie`; refresh once with 2FA when expired:

```bash
fastlane spaceauth -u kars@kargn.as
```

Run the snippets below through Homebrew fastlane's ruby + gem path (mirror
`scripts/asc-review.zsh` in the sibling skill, which sets `GEM_HOME` to
fastlane's private gems and `require "spaceship"`, then
`Spaceship::ConnectAPI.login`).

## The two gotchas (both already bit us)

### 1. Creating an internal group → `publicLinkLimit cannot be applied to internal group`

fastlane's `create_beta_group` always sends `publicLinkLimit`, which App Store
Connect rejects for internal groups. Bypass the helper and POST the minimal body
directly:

```ruby
client = Spaceship::ConnectAPI.client.test_flight_request_client
client.post("v1/betaGroups", {
  data: {
    type: "betaGroups",
    attributes: { name: "Internal", isInternalGroup: true, hasAccessToAllBuilds: true },
    relationships: { app: { data: { type: "apps", id: "6779669255" } } }
  }
})
```

`hasAccessToAllBuilds: true` is what makes future builds auto-distribute.

### 2. Adding a tester → `Tester(s) cannot be assigned`

An email-only / external tester cannot be dropped into an internal group with
`add_beta_tester_to_group`. Use the bulk-assignment endpoint instead, which
creates+assigns the internal tester in one call:

```ruby
group = Spaceship::ConnectAPI::BetaGroup.all(app_id: "6779669255")
             .find { |g| g.is_internal_group }
Spaceship::ConnectAPI.post_bulk_beta_tester_assignments(
  beta_group_id: group.id,
  beta_testers: [{ email: "kars@kargn.as", first_name: "Sangrak", last_name: "Choi" }]
)
```

The tester then shows `ASSIGNED` and receives processed builds for every version.

## Verify

The TestFlight builds section of
`.claude/skills/appstore-review-status/scripts/asc-review.zsh` lists processed
builds and their states; a tester in the all-builds internal group can install
any `READY_TO_TEST` build from the TestFlight app.
