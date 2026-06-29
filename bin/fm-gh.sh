#!/usr/bin/env bash
# Route a GitHub CLI invocation to the gh account that owns the target repo, then
# exec the real CLI (gh-axi preferred, else gh) with all passed args unchanged.
#
# The fleet spans repos owned by different GitHub accounts, but the gh CLI has one
# active account at a time, so a PR operation fails when the wrong account is
# active. This wrapper picks the owning account per repo and switches to it
# idempotently before running the command, so callers never hand-switch.
#
# Usage: fm-gh.sh [-R <owner>/<repo>] <args...>
#   The target repo owner is resolved from an explicit -R/--repo <owner>/<repo>
#   (also accepts <host>/<owner>/<repo>) when present, otherwise from the origin
#   remote URL of the git repo in the current directory.
#   The owner is looked up in config/gh-accounts under the active firstmate home
#   (lines "owner=account"; "#" starts a comment; blank lines are ignored). When a
#   mapping is found and that account is not already active, `gh auth switch`
#   switches to it - strictly idempotent (never switches when already active). When
#   no mapping is found the active account is left unchanged and a warning goes to
#   stderr; this is never fatal.
#   Account switching is a gh-native operation (gh-axi only wraps the command
#   layer, not the shared auth state), so status/switch use gh; if gh is absent,
#   routing is skipped with a warning and the command still runs.
#   All routing chatter goes to stderr; stdout carries only the exec'd CLI's
#   output, so command substitution around fm-gh.sh (e.g. the merge poll) stays
#   clean. All passed args, -R included, are forwarded to the real CLI verbatim.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ACCOUNTS="$CONFIG/gh-accounts"

warn() { printf 'fm-gh: %s\n' "$1" >&2; }

# Extract OWNER from a gh -R/--repo value: [HOST/]OWNER/REPO.
owner_from_repo_flag() {
  local v=${1%/}
  case "$v" in
    */*/*) printf '%s\n' "$v" | cut -d/ -f2 ;;
    */*)   printf '%s\n' "$v" | cut -d/ -f1 ;;
    *)     return 1 ;;
  esac
}

# Extract OWNER from a git remote URL (https/ssh URL, scp-like, etc).
owner_from_remote_url() {
  local url=$1 rest
  url=${url%.git}
  url=${url%/}
  case "$url" in
    *://*)
      rest=${url#*://}   # [user@]host/owner/repo
      rest=${rest#*@}    # drop optional user@
      rest=${rest#*/}    # drop host/ -> owner/repo[/...]
      ;;
    *@*:*) rest=${url#*:} ;;   # scp-like: user@host:owner/repo
    *) return 1 ;;
  esac
  case "$rest" in
    */*) printf '%s\n' "${rest%%/*}" ;;
    *)   return 1 ;;
  esac
}

# The gh account that owns OWNER, from config/gh-accounts (empty if unmapped).
account_for_owner() {
  local owner=$1 line key val
  [ -f "$ACCOUNTS" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
    val=$(printf '%s' "${line#*=}" | tr -d '[:space:]')
    [ -n "$key" ] && [ -n "$val" ] || continue
    if [ "$key" = "$owner" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done < "$ACCOUNTS"
  return 1
}

# The currently active gh account (empty if none / not determinable). Walks
# `gh auth status`: each block names an account on its "Logged in to" line and
# flags the active one with "Active account: true".
gh_active_account() {
  "$GH_AUTH" auth status 2>/dev/null | awk '
    /Logged in to/ { for (i = 1; i <= NF; i++) if ($i == "account") acct = $(i + 1) }
    /Active account: true/ { print acct; exit }
  '
}

# Resolve the CLI to exec (prefer gh-axi) and the gh binary for auth ops (gh only).
if command -v gh-axi >/dev/null 2>&1; then
  EXEC_BIN=gh-axi
elif command -v gh >/dev/null 2>&1; then
  EXEC_BIN=gh
else
  echo "fm-gh: neither gh-axi nor gh is on PATH" >&2
  exit 127
fi
GH_AUTH=
command -v gh >/dev/null 2>&1 && GH_AUTH=gh

# Find an explicit -R/--repo value without disturbing the args we forward.
REPO_FLAG=
ARGS=("$@")
n=${#ARGS[@]}
i=0
while [ "$i" -lt "$n" ]; do
  a=${ARGS[$i]}
  case "$a" in
    -R|--repo)
      j=$((i + 1))
      [ "$j" -lt "$n" ] && REPO_FLAG=${ARGS[$j]}
      ;;
    --repo=*) REPO_FLAG=${a#--repo=} ;;
    -R=*)     REPO_FLAG=${a#-R=} ;;
  esac
  i=$((i + 1))
done

# Resolve the target repo owner.
OWNER=
if [ -n "$REPO_FLAG" ]; then
  OWNER=$(owner_from_repo_flag "$REPO_FLAG" || true)
  [ -n "$OWNER" ] || warn "could not parse owner from -R '$REPO_FLAG'; leaving the active gh account unchanged"
else
  ORIGIN=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN" ]; then
    OWNER=$(owner_from_remote_url "$ORIGIN" || true)
    [ -n "$OWNER" ] || warn "could not parse owner from origin remote '$ORIGIN'; leaving the active gh account unchanged"
  else
    warn "no -R given and no origin remote in $(pwd); leaving the active gh account unchanged"
  fi
fi

# Route to the owning account, idempotently. Never fatal.
if [ -n "$OWNER" ]; then
  if [ -z "$GH_AUTH" ]; then
    warn "gh is not on PATH; cannot switch accounts for owner '$OWNER'; leaving the active account unchanged"
  elif ACCOUNT=$(account_for_owner "$OWNER"); then
    ACTIVE=$(gh_active_account || true)
    if [ "$ACCOUNT" = "$ACTIVE" ]; then
      : # already active; idempotent no-op
    elif "$GH_AUTH" auth switch --user "$ACCOUNT" 1>&2; then
      :
    else
      warn "gh auth switch to '$ACCOUNT' (owner '$OWNER') failed; leaving the active account as-is"
    fi
  else
    warn "no account mapping for owner '$OWNER' in $ACCOUNTS; leaving the active gh account unchanged"
  fi
fi

exec "$EXEC_BIN" "$@"
