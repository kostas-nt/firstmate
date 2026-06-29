#!/usr/bin/env bash
# Behavior tests for descriptive work-branch names (decoupled from the task id).
#
# Branches used to be hardcoded fm/<task-id>. Now a task may carry a descriptive
# name: fm-spawn slugifies it and records branch=<name> in state/<id>.meta, fm-brief
# writes the same name into the crewmate's branch/"ready in branch" instructions, and
# the consumers (review-diff, merge-local, promote) read branch= from meta. With no
# --branch the name falls back to fm/<id>, so the no-flag path and in-flight tasks
# (whose meta predates branch=) stay backward compatible.
#
# Covered here:
#   - fm-branch-lib: slugify, resolve (with fm/<id> fallback), meta read + fallback
#   - fm-brief: the branch step and local-only "ready in branch" use the resolved name
#   - fm-spawn: records branch= in meta (default and --branch), rejects --branch with
#               batch dispatch and --secondmate
#   - fm-review-diff / fm-merge-local / fm-promote: honor a recorded branch= and fall
#               back to fm/<id> when meta has none
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-branch-lib.sh
. "$ROOT/bin/fm-branch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-name)
mkdir -p "$TMP_ROOT"
fm_git_identity

# --- fm-branch-lib --------------------------------------------------------------

test_branch_slug() {
  local raw expect got
  while IFS='|' read -r raw expect; do
    [ -n "$raw$expect" ] || continue
    got=$(fm_branch_slug "$raw")
    [ "$got" = "$expect" ] || fail "slug '$raw' -> '$got', expected '$expect'"
  done <<'ROWS'
Fix Login Timeout|fix-login-timeout
feat/Add Thing|feat/add-thing
gh-account-routing-and-branch-names|gh-account-routing-and-branch-names
Weird@@Chars!!|weird-chars
/leading/and/trailing/|leading/and/trailing
a..b|a.b
a/./b|a/b
feat/x.lock|feat/x
thing.lock.lock|thing
ROWS
  pass "fm_branch_slug: lowercases, maps unsafe chars, collapses '..'//, trims separators and '.lock'"
}

test_resolve_branch_fallback() {
  [ "$(fm_resolve_branch task-x1 '')" = "fm/task-x1" ] || fail "empty raw should fall back to fm/<id>"
  [ "$(fm_resolve_branch task-x1 'My Branch')" = "my-branch" ] || fail "raw should slugify"
  # Pathological input that slugifies to nothing falls back to fm/<id>.
  [ "$(fm_resolve_branch task-x1 '@@@')" = "fm/task-x1" ] || fail "all-unsafe raw should fall back to fm/<id>"
  pass "fm_resolve_branch: slugifies a name, falls back to fm/<id> for empty/pathological input"
}

test_branch_from_meta() {
  local meta="$TMP_ROOT/from-meta.meta"
  fm_write_meta "$meta" "kind=ship" "branch=cool-feature"
  [ "$(fm_branch_from_meta "$meta" task-x1)" = "cool-feature" ] || fail "recorded branch= not read"
  fm_write_meta "$meta" "kind=ship"
  [ "$(fm_branch_from_meta "$meta" task-x1)" = "fm/task-x1" ] || fail "missing branch= should fall back to fm/<id>"
  [ "$(fm_branch_from_meta "$TMP_ROOT/nope.meta" task-x1)" = "fm/task-x1" ] || fail "absent meta should fall back to fm/<id>"
  pass "fm_branch_from_meta: reads branch=, falls back to fm/<id> when missing/absent"
}

# --- fm-brief -------------------------------------------------------------------

run_brief() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-brief.sh" "$@"
}

test_brief_default_branch() {
  local home="$TMP_ROOT/brief-default"
  mkdir -p "$home/data"
  run_brief "$home" bid-default-a1 alpha >/dev/null 2>&1
  assert_grep "git checkout -b fm/bid-default-a1" "$home/data/bid-default-a1/brief.md" \
    "default ship brief did not use the fm/<id> branch"
  pass "fm-brief: with no --branch, the branch step is fm/<id>"
}

test_brief_custom_branch() {
  local home="$TMP_ROOT/brief-custom"
  mkdir -p "$home/data"
  run_brief "$home" bid-custom-b2 alpha --branch "My Feature" >/dev/null 2>&1
  local brief="$home/data/bid-custom-b2/brief.md"
  assert_grep "git checkout -b my-feature" "$brief" "custom branch not slugified into the branch step"
  assert_no_grep "git checkout -b fm/bid-custom-b2" "$brief" "custom branch did not replace the fm/<id> default"
  pass "fm-brief: --branch sets the (slugified) branch step name"
}

test_brief_local_only_ready_in_branch() {
  local home="$TMP_ROOT/brief-lo"
  mkdir -p "$home/data"
  printf -- '- alpha [local-only] - test project (added 2026-01-01)\n' > "$home/data/projects.md"
  run_brief "$home" bid-lo-c3 alpha --branch "Cool Thing" >/dev/null 2>&1
  local brief="$home/data/bid-lo-c3/brief.md"
  assert_grep "git checkout -b cool-thing" "$brief" "local-only brief branch step did not use the custom name"
  assert_grep "ready in branch cool-thing" "$brief" "local-only 'ready in branch' did not use the custom name"
  assert_no_grep "ready in branch fm/bid-lo-c3" "$brief" "local-only 'ready in branch' still used fm/<id>"
  pass "fm-brief: local-only branch step and 'ready in branch' use the resolved branch name"
}

# --- fm-spawn: branch recorded in meta (hermetic fake tmux + treehouse) ----------

# Fake tmux: reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd, names the
# session on '#S', and swallows window ops. Plus a no-op treehouse. Echoes the fakebin.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A fresh project repo (on main, one commit) plus a genuine isolated worktree, so
# fm-spawn's isolation guard is satisfied. Echoes "<proj> <wt>".
make_proj_and_worktree() {
  local proj="$1/proj" wt="$1/wt"
  git init -q -b main "$proj"
  git -C "$proj" commit -q --allow-empty -m init
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  printf '%s %s\n' "$proj" "$wt"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex "$@" 2>&1
}

test_spawn_records_default_branch() {
  local home="$TMP_ROOT/spawn-default" fakebin out pw proj wt status
  mkdir -p "$home/data/spawn-def-d4"
  printf 'brief\n' > "$home/data/spawn-def-d4/brief.md"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake-1")
  pw=$(make_proj_and_worktree "$TMP_ROOT/spawn-pw-1"); read -r proj wt <<<"$pw"

  out=$(run_spawn "$home" spawn-def-d4 "$proj" "$wt" "$fakebin"); status=$?
  [ "$status" -eq 0 ] || fail "default spawn failed: $out"
  assert_grep "branch=fm/spawn-def-d4" "$home/state/spawn-def-d4.meta" "meta did not record the fm/<id> default branch"
  assert_contains "$out" "branch=fm/spawn-def-d4" "spawned line did not report the default branch"
  pass "fm-spawn: records branch=fm/<id> in meta when no --branch is given"
}

test_spawn_records_custom_branch() {
  local home="$TMP_ROOT/spawn-custom" fakebin out pw proj wt status
  mkdir -p "$home/data/spawn-cust-e5"
  printf 'brief\n' > "$home/data/spawn-cust-e5/brief.md"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake-2")
  pw=$(make_proj_and_worktree "$TMP_ROOT/spawn-pw-2"); read -r proj wt <<<"$pw"

  out=$(run_spawn "$home" spawn-cust-e5 "$proj" "$wt" "$fakebin" --branch "Add OAuth Login"); status=$?
  [ "$status" -eq 0 ] || fail "custom-branch spawn failed: $out"
  assert_grep "branch=add-oauth-login" "$home/state/spawn-cust-e5.meta" "meta did not record the slugified custom branch"
  assert_no_grep "branch=fm/spawn-cust-e5" "$home/state/spawn-cust-e5.meta" "meta still recorded the fm/<id> default"
  pass "fm-spawn: --branch records the slugified descriptive branch in meta"
}

test_spawn_rejects_branch_in_batch() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" a-z1=projects/x b-z2=projects/y --branch foo 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch with --branch should exit non-zero"
  assert_contains "$out" "--branch is not supported with batch dispatch" "batch+--branch lacked the rejection message"
  pass "fm-spawn: --branch is rejected with batch dispatch"
}

test_spawn_rejects_branch_with_secondmate() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sid-z3 --secondmate --branch foo 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--secondmate with --branch should exit non-zero"
  assert_contains "$out" "--branch is not valid for --secondmate" "secondmate+--branch lacked the rejection message"
  pass "fm-spawn: --branch is rejected with --secondmate"
}

# --- consumers honor branch= with the fm/<id> fallback --------------------------

# Build origin + project clone + a worktree on <branch> carrying one file commit, so
# fm-review-diff has a remote base to diff against. Echoes nothing; writes under $case.
make_review_case() {
  local case=$1 branch=$2
  mkdir -p "$case/state"
  git init -q --bare "$case/origin.git"
  git -C "$case/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case/origin.git" "$case/seed" 2>/dev/null
  git -C "$case/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$case/seed" push -q origin main
  rm -rf "$case/seed"
  git clone -q "$case/origin.git" "$case/project"
  git -C "$case/project" remote set-head origin main 2>/dev/null || true
  git -C "$case/project" worktree add -q -b "$branch" "$case/wt" main
  printf 'hello\n' > "$case/wt/feature.txt"
  git -C "$case/wt" add feature.txt
  git -C "$case/wt" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  touch "$case/state/.last-watcher-beat"
}

run_review_diff() {
  local case=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" \
    "$ROOT/bin/fm-review-diff.sh" "$@" 2>"$case/stderr"
}

test_review_diff_honors_recorded_branch() {
  local case="$TMP_ROOT/review-recorded" out
  make_review_case "$case" descriptive-feature
  fm_write_meta "$case/state/rid-f6.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=ship" "mode=no-mistakes" "branch=descriptive-feature"
  out=$(run_review_diff "$case" rid-f6)
  assert_contains "$out" "feature.txt" "review-diff did not diff the recorded descriptive branch"
  assert_no_grep "does not exist" "$case/stderr" "review-diff errored resolving the recorded branch"
  pass "fm-review-diff: honors a recorded descriptive branch= from meta"
}

test_review_diff_fallback_to_fm_id() {
  local case="$TMP_ROOT/review-fallback" out
  make_review_case "$case" fm/rid-g7
  # Meta has NO branch= (in-flight task predating the field); HEAD is on fm/<id>.
  fm_write_meta "$case/state/rid-g7.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=ship" "mode=no-mistakes"
  out=$(run_review_diff "$case" rid-g7)
  assert_contains "$out" "feature.txt" "review-diff fallback did not diff the fm/<id> branch"
  assert_no_grep "does not exist" "$case/stderr" "review-diff fallback errored resolving fm/<id>"
  pass "fm-review-diff: falls back to fm/<id> when meta has no branch="
}

# Build a local-only project on main plus a branch that fast-forwards main, carrying
# one file commit. <branch> is created and advanced via a worktree.
make_merge_case() {
  local case=$1 branch=$2
  mkdir -p "$case/state"
  git init -q -b main "$case/project"
  git -C "$case/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$case/project" worktree add -q -b "$branch" "$case/wt" main
  printf 'x\n' > "$case/wt/f.txt"
  git -C "$case/wt" add f.txt
  git -C "$case/wt" -c user.email=t@t -c user.name=t commit -q -m feature
  touch "$case/state/.last-watcher-beat"
}

run_merge_local() {
  local case=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" \
    "$ROOT/bin/fm-merge-local.sh" "$@" 2>"$case/stderr"
}

test_merge_local_honors_recorded_branch() {
  local case="$TMP_ROOT/merge-recorded" out
  make_merge_case "$case" ship-it-now
  fm_write_meta "$case/state/mid-h8.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=ship" "mode=local-only" "branch=ship-it-now"
  out=$(run_merge_local "$case" mid-h8) || fail "merge-local failed: $(cat "$case/stderr")"
  assert_contains "$out" "merged ship-it-now into local main" "merge-local did not merge the recorded branch"
  pass "fm-merge-local: honors a recorded descriptive branch= from meta"
}

test_merge_local_fallback_to_fm_id() {
  local case="$TMP_ROOT/merge-fallback" out
  make_merge_case "$case" fm/mid-i9
  fm_write_meta "$case/state/mid-i9.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=ship" "mode=local-only"
  out=$(run_merge_local "$case" mid-i9) || fail "merge-local fallback failed: $(cat "$case/stderr")"
  assert_contains "$out" "merged fm/mid-i9 into local main" "merge-local fallback did not merge fm/<id>"
  pass "fm-merge-local: falls back to fm/<id> when meta has no branch="
}

run_promote() {
  local case=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case" FM_STATE_OVERRIDE="$case/state" \
    "$ROOT/bin/fm-promote.sh" "$@" 2>"$case/stderr"
}

test_promote_prints_recorded_branch() {
  local case="$TMP_ROOT/promote-recorded" out
  mkdir -p "$case/state"; touch "$case/state/.last-watcher-beat"
  fm_write_meta "$case/state/pid-j1.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=scout" "mode=no-mistakes" "branch=repro-the-bug"
  out=$(run_promote "$case" pid-j1) || fail "promote failed: $(cat "$case/stderr")"
  assert_contains "$out" "create branch repro-the-bug" "promote ship instructions did not use the recorded branch"
  pass "fm-promote: ship instructions use a recorded descriptive branch="
}

test_promote_fallback_to_fm_id() {
  local case="$TMP_ROOT/promote-fallback" out
  mkdir -p "$case/state"; touch "$case/state/.last-watcher-beat"
  fm_write_meta "$case/state/pid-k2.meta" \
    "worktree=$case/wt" "project=$case/project" "kind=scout" "mode=no-mistakes"
  out=$(run_promote "$case" pid-k2) || fail "promote fallback failed: $(cat "$case/stderr")"
  assert_contains "$out" "create branch fm/pid-k2" "promote fallback did not use fm/<id>"
  pass "fm-promote: ship instructions fall back to fm/<id> when meta has no branch="
}

test_branch_slug
test_resolve_branch_fallback
test_branch_from_meta
test_brief_default_branch
test_brief_custom_branch
test_brief_local_only_ready_in_branch
test_spawn_records_default_branch
test_spawn_records_custom_branch
test_spawn_rejects_branch_in_batch
test_spawn_rejects_branch_with_secondmate
test_review_diff_honors_recorded_branch
test_review_diff_fallback_to_fm_id
test_merge_local_honors_recorded_branch
test_merge_local_fallback_to_fm_id
test_promote_prints_recorded_branch
test_promote_fallback_to_fm_id
