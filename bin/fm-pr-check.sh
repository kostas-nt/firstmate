#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and a verified pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# GitHub lookups (the head verification here and the merge poll's `pr view`) route
# through bin/fm-gh.sh from inside the worktree, so each runs under the gh account
# that owns the repo (per config/gh-accounts) regardless of which account is active.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
WT=
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCAL_HEAD=
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
    if [ -n "$LOCAL_HEAD" ] && { command -v gh-axi >/dev/null 2>&1 || command -v gh >/dev/null 2>&1; }; then
      if REMOTE_HEAD=$(cd "$WT" && "$FM_ROOT/bin/fm-gh.sh" pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
          PR_HEAD=$LOCAL_HEAD
        fi
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

# The poll resolves the PR state via command substitution, so only the PR state may
# reach stdout (the check contract). With a known worktree it cd's there and routes
# `pr view` through fm-gh.sh so the merge check runs under the repo's owning gh account
# (fm-gh infers the owner from origin - passing -R is not an option, gh rejects -R
# alongside a PR URL - and sends all routing chatter to stderr). Without a worktree
# there is no origin to infer from, so routing through fm-gh would misread the owner
# from the watcher's own cwd; the poll then calls the CLI directly (gh-axi preferred)
# on the active account rather than risk switching to the wrong one.
if [ -n "$WT" ]; then
  cat > "$STATE/$ID.check.sh" <<EOF
cd '$WT' 2>/dev/null || true
state=\$('$FM_ROOT/bin/fm-gh.sh' pr view '$URL' --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
else
  cat > "$STATE/$ID.check.sh" <<EOF
if command -v gh-axi >/dev/null 2>&1; then gh_bin=gh-axi; else gh_bin=gh; fi
state=\$("\$gh_bin" pr view '$URL' --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
fi
echo "armed: state/$ID.check.sh polls $URL"
