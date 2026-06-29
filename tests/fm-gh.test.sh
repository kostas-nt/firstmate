#!/usr/bin/env bash
# Behavior tests for bin/fm-gh.sh: per-repo GitHub account auto-routing.
#
# fm-gh.sh resolves the target repo owner (from -R/--repo, else the cwd's origin
# remote), looks the owner up in config/gh-accounts, switches the active gh account
# to the mapped one when it differs (idempotent), then execs the real CLI (gh-axi
# preferred) with all args forwarded verbatim.
#
# The stubs make this hermetic: `gh` serves `auth status`/`auth switch` from env-
# pointed state files and records any other invocation; `gh-axi` only records its
# invocation, so it stands in for the exec target. Tests assert on the switch log
# (did we switch, and to whom) and the exec log (which CLI ran, with which args).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GH="$ROOT/bin/fm-gh.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-tests)
fm_git_identity

# A fakebin with gh + gh-axi. gh answers `auth status` (active = $GH_ACTIVE_FILE)
# and `auth switch --user X` (records X to $GH_SWITCH_LOG and updates the active
# file); any other gh call is logged to $GH_EXEC_LOG. gh-axi only logs to
# $GH_EXEC_LOG. Pass want_gh_axi=no to omit gh-axi (exec-fallback case).
make_fakebin() {
  local dir=$1 want_gh_axi=${2:-yes} fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status")
    active=$(cat "$GH_ACTIVE_FILE" 2>/dev/null || true)
    for acct in alice bob acme-bot nlp-bot; do
      printf '  Logged in to github.com account %s (keyring)\n' "$acct"
      if [ "$acct" = "$active" ]; then
        printf '  - Active account: true\n'
      else
        printf '  - Active account: false\n'
      fi
    done
    exit 0 ;;
  "auth switch")
    shift 2
    user=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --user|-u) user=${2:-}; shift 2 ;;
        --user=*)  user=${1#--user=}; shift ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$user" > "$GH_ACTIVE_FILE"
    printf '%s\n' "$user" >> "$GH_SWITCH_LOG"
    echo "Switched active account for github.com to $user"
    exit 0 ;;
esac
printf 'gh %s\n' "$*" >> "$GH_EXEC_LOG"
exit 0
SH
  chmod +x "$fakebin/gh"
  if [ "$want_gh_axi" = yes ]; then
    cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$GH_EXEC_LOG"
exit 0
SH
    chmod +x "$fakebin/gh-axi"
  fi
  printf '%s\n' "$fakebin"
}

FAKEBIN=$(make_fakebin "$TMP_ROOT/full")
FAKEBIN_GH_ONLY=$(make_fakebin "$TMP_ROOT/ghonly" no)

# PATH with every directory holding a gh-axi executable removed, so the exec-fallback
# case can prove fm-gh uses gh when gh-axi is genuinely absent (the test host ships a
# real gh-axi that would otherwise leak in through the inherited PATH).
clean_path_without_gh_axi() {
  local p out= oldifs=$IFS
  IFS=:
  # shellcheck disable=SC2086  # deliberate word-split of PATH on ':'
  set -- $PATH
  IFS=$oldifs
  for p in "$@"; do
    [ -n "$p" ] || continue
    [ -x "$p/gh-axi" ] && continue
    out="${out:+$out:}$p"
  done
  printf '%s\n' "$out"
}
CLEAN_PATH=$(clean_path_without_gh_axi)

# Fresh per-case state: config/, active-account file, switch + exec logs. Echoes the
# case dir. $active seeds the currently-active gh account.
setup_case() {
  local name=$1 active=$2 d
  d="$TMP_ROOT/$name"
  mkdir -p "$d/config"
  printf '%s\n' "$active" > "$d/active"
  : > "$d/switch.log"
  : > "$d/exec.log"
  : > "$d/stderr"
  printf '%s\n' "$d"
}

# A throwaway git repo whose origin remote URL is exactly $url (no commit needed;
# only `git remote get-url origin` is consulted).
mk_repo_with_origin() {
  local dir=$1 url=$2
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
}

# run_gh <case-dir> <cwd> <fm-gh args...>: run fm-gh.sh from <cwd> with the case's
# state wired in and the full (gh + gh-axi) fakebin on PATH.
run_gh() {
  local d=$1 cwd=$2
  shift 2
  ( cd "$cwd" && \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" FM_CONFIG_OVERRIDE="$d/config" \
    GH_ACTIVE_FILE="$d/active" GH_SWITCH_LOG="$d/switch.log" GH_EXEC_LOG="$d/exec.log" \
    PATH="$FAKEBIN:$PATH" \
    "$GH" "$@" 2>"$d/stderr" )
}

test_owner_from_R_flag_switches() {
  local d
  d=$(setup_case r-flag bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  run_gh "$d" "$TMP_ROOT" -R acme/widgets pr view 123
  assert_grep "acme-bot" "$d/switch.log" "did not switch to the -R owner's account"
  assert_grep "gh-axi -R acme/widgets pr view 123" "$d/exec.log" \
    "did not exec gh-axi with all args (including -R) forwarded verbatim"
  pass "fm-gh: resolves owner from -R and switches to the mapped account"
}

test_owner_from_host_qualified_R() {
  local d
  d=$(setup_case r-host bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  run_gh "$d" "$TMP_ROOT" --repo github.com/acme/widgets pr list
  assert_grep "acme-bot" "$d/switch.log" "did not parse owner from HOST/OWNER/REPO --repo value"
  pass "fm-gh: resolves owner from a host-qualified --repo value"
}

test_owner_from_https_origin() {
  local d
  d=$(setup_case origin-https bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  mk_repo_with_origin "$d/repo" "https://github.com/acme/widgets.git"
  run_gh "$d" "$d/repo" pr view 1
  assert_grep "acme-bot" "$d/switch.log" "did not infer owner from an https origin remote"
  pass "fm-gh: infers owner from the cwd's https origin remote"
}

test_owner_from_scp_origin() {
  local d
  d=$(setup_case origin-scp bob)
  printf '%s\n' 'nlp-platform=nlp-bot' > "$d/config/gh-accounts"
  mk_repo_with_origin "$d/repo" "git@github.com:nlp-platform/engine.git"
  run_gh "$d" "$d/repo" pr view 1
  assert_grep "nlp-bot" "$d/switch.log" "did not infer owner from an scp-style origin remote"
  pass "fm-gh: infers owner from the cwd's scp-style origin remote"
}

test_no_switch_when_already_active() {
  local d rc
  d=$(setup_case already-active acme-bot)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  run_gh "$d" "$TMP_ROOT" -R acme/widgets pr view 1
  rc=$?
  expect_code 0 "$rc" "idempotent path should still exit 0"
  [ ! -s "$d/switch.log" ] || fail "fm-gh switched even though the mapped account was already active"
  assert_grep "gh-axi -R acme/widgets pr view 1" "$d/exec.log" "command did not run on the already-active path"
  pass "fm-gh: never switches when the owning account is already active (idempotent)"
}

test_unknown_owner_warns_but_runs() {
  local d rc
  d=$(setup_case unknown-owner bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  run_gh "$d" "$TMP_ROOT" -R other-org/thing pr view 1
  rc=$?
  expect_code 0 "$rc" "an unmapped owner must not be fatal"
  [ ! -s "$d/switch.log" ] || fail "fm-gh switched for an owner with no mapping"
  assert_grep "no account mapping for owner 'other-org'" "$d/stderr" \
    "fm-gh did not warn about the missing mapping"
  assert_grep "gh-axi -R other-org/thing pr view 1" "$d/exec.log" \
    "fm-gh did not still run the command for an unmapped owner"
  pass "fm-gh: unmapped owner leaves the account unchanged, warns, and still runs (never fails)"
}

test_no_owner_resolved_warns_but_runs() {
  local d rc
  d=$(setup_case no-owner bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  # cwd ($d) is not a git repo and no -R is given: owner cannot be resolved.
  run_gh "$d" "$d" pr view 1
  rc=$?
  expect_code 0 "$rc" "an unresolvable owner must not be fatal"
  [ ! -s "$d/switch.log" ] || fail "fm-gh switched with no owner resolved"
  assert_grep "no origin remote" "$d/stderr" "fm-gh did not warn about the missing origin remote"
  assert_grep "gh-axi pr view 1" "$d/exec.log" "fm-gh did not still run the command with no owner resolved"
  pass "fm-gh: no -R and no origin leaves the account unchanged, warns, and still runs"
}

test_config_comments_and_whitespace() {
  local d
  d=$(setup_case cfg-format bob)
  printf '%s\n' '# per-repo account map' '' '  acme = acme-bot  ' 'nlp-platform=nlp-bot' \
    > "$d/config/gh-accounts"
  run_gh "$d" "$TMP_ROOT" -R acme/widgets pr view 1
  assert_grep "acme-bot" "$d/switch.log" "comments/blank-line/whitespace handling broke the lookup"
  pass "fm-gh: ignores comments and blank lines and tolerates whitespace around '='"
}

test_exec_falls_back_to_gh_without_gh_axi() {
  local d
  d=$(setup_case exec-fallback bob)
  printf '%s\n' 'acme=acme-bot' > "$d/config/gh-accounts"
  # gh-only fakebin first, then a PATH scrubbed of every real gh-axi: gh-axi is
  # genuinely absent, so fm-gh must route via gh and exec gh.
  ( cd "$TMP_ROOT" && \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" FM_CONFIG_OVERRIDE="$d/config" \
    GH_ACTIVE_FILE="$d/active" GH_SWITCH_LOG="$d/switch.log" GH_EXEC_LOG="$d/exec.log" \
    PATH="$FAKEBIN_GH_ONLY:$CLEAN_PATH" \
    "$GH" -R acme/widgets pr view 1 2>"$d/stderr" )
  assert_grep "acme-bot" "$d/switch.log" "fallback path did not switch via gh"
  assert_grep "gh -R acme/widgets pr view 1" "$d/exec.log" "did not fall back to gh as the exec target"
  ! grep -F 'gh-axi ' "$d/exec.log" >/dev/null || fail "exec log unexpectedly shows gh-axi when it is absent"
  pass "fm-gh: execs gh when gh-axi is not on PATH (still routing the account via gh)"
}

test_owner_from_R_flag_switches
test_owner_from_host_qualified_R
test_owner_from_https_origin
test_owner_from_scp_origin
test_no_switch_when_already_active
test_unknown_owner_warns_but_runs
test_no_owner_resolved_warns_but_runs
test_config_comments_and_whitespace
test_exec_falls_back_to_gh_without_gh_axi
