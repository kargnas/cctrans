#!/usr/bin/env zsh
# Run asc_review.rb under fastlane's bundled ruby + spaceship gem.
#
# WHY a wrapper: spaceship is not installed in the system ruby; it ships inside
# Homebrew fastlane's private gem home. We discover that layout dynamically so a
# `brew upgrade fastlane` (new version dir) does not break the skill.
#
# Usage:  scripts/asc-review.zsh
# Override target via env:  ASC_APP_ID=... ASC_TEAM_ID=... ASC_USER=... scripts/asc-review.zsh
set -euo pipefail

script_dir="${0:A:h}"

# CCTrans defaults — override via env to target another app/team/account.
export ASC_USER="${ASC_USER:-kars@kargn.as}"
export ASC_APP_ID="${ASC_APP_ID:-6779669255}"
export ASC_TEAM_ID="${ASC_TEAM_ID:-520806}"
# spaceship reads the App Store Connect team from FASTLANE_ITC_TEAM_ID. Without
# it, accounts on multiple teams abort with "Multiple teams found" in a
# non-interactive shell.
export FASTLANE_ITC_TEAM_ID="${FASTLANE_ITC_TEAM_ID:-$ASC_TEAM_ID}"
# Skip the interactive 2FA-session upgrade prompt; we rely on the stored cookie.
export SPACESHIP_SKIP_2FA_UPGRADE=1

# Discover fastlane's ruby + gem paths (Homebrew layout); newest version wins.
ruby_bin="/opt/homebrew/opt/ruby/bin"
fl_gem_home=$(print -rl -- ${HOME}/.local/share/fastlane/*(/N) 2>/dev/null | sort -V | tail -1)
fl_libexec=$(print -rl -- /opt/homebrew/Cellar/fastlane/*/libexec(/N) 2>/dev/null | sort -V | tail -1)

if [[ -z "$fl_gem_home" || -z "$fl_libexec" || ! -x "$ruby_bin/ruby" ]]; then
  print -u2 "ERROR: Homebrew fastlane/ruby not found."
  print -u2 "  Install with: brew install fastlane"
  print -u2 "  Looked for ~/.local/share/fastlane/<ver> and /opt/homebrew/Cellar/fastlane/<ver>/libexec"
  exit 1
fi

# Filter known-harmless startup noise (spaceship/ffi print to BOTH streams), but
# keep real errors visible. pipefail makes the ruby exit code win over grep's, so
# a LOGIN_FAILED (exit 2) still propagates. < /dev/null prevents an unexpected
# interactive prompt (2FA / team pick) from hanging the run.
PATH="${ruby_bin}:${PATH}" \
GEM_HOME="$fl_gem_home" \
GEM_PATH="${fl_gem_home}:${fl_libexec}" \
  ruby "${script_dir}/asc_review.rb" < /dev/null 2>&1 \
    | grep -vE 'Insecure world writable|Ignoring ffi|gem pristine|local proxy, use SPACESHIP_DEBUG'
