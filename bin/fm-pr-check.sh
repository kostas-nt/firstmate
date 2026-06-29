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

# The poll routes `pr view` through fm-gh.sh from inside the worktree so the merge
# check runs under the repo's owning gh account. cd into the worktree (when known)
# lets fm-gh.sh infer that owner from the origin remote; passing -R is not an option
# here because gh rejects -R alongside a PR URL. All routing chatter goes to stderr,
# so the command substitution captures only the PR state - the check contract holds.
cat > "$STATE/$ID.check.sh" <<EOF
cd '$WT' 2>/dev/null || true
state=\$('$FM_ROOT/bin/fm-gh.sh' pr view '$URL' --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
