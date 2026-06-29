# shellcheck shell=bash
# fm-branch-lib.sh - resolve a task's work-branch name.
#
# Work branches used to be hardcoded as fm/<task-id>, which leaked the internal id
# (and its random suffix) onto PRs and branch lists. A task may instead carry a
# descriptive branch name; fm-spawn records it as branch=<name> in state/<id>.meta
# and fm-brief writes it into the crewmate's branch/"ready in branch" instructions.
# The consumers (review-diff, merge-local, promote) read branch= from meta. When no
# descriptive name is supplied the name falls back to fm/<id>, so in-flight tasks and
# the no-flag path stay byte-for-byte backward compatible.
#
# Usage: . bin/fm-branch-lib.sh

# fm_branch_slug <raw>: echo a conservative, valid git branch ref derived from <raw>.
# Lowercases, maps every char outside [a-z0-9._/-] to '-', then collapses and trims
# the sequences git check-ref-format forbids ('..', '//', leading/trailing '-./',
# '/.'/'./', and a trailing '.lock'). Echoes the empty string when <raw> slugifies to
# nothing, so callers fall back to the fm/<id> default.
fm_branch_slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9._/-' '-')
  s=$(printf '%s' "$s" | sed \
    -e 's/\.\.*/./g' \
    -e 's/--*/-/g' \
    -e 's#/\.#/#g' \
    -e 's#\./#/#g' \
    -e 's#//*#/#g' \
    -e 's#^[-./][-./]*##' \
    -e ':t' \
    -e 's#[-./][-./]*$##' \
    -e 's#\.lock$##' \
    -e 'tt')
  printf '%s' "$s"
}

# fm_resolve_branch <id> [raw]: echo the task's branch name. Uses the slugified
# <raw> when it yields a non-empty ref, otherwise the fm/<id> default.
fm_resolve_branch() {
  local id=$1 raw=${2:-} slug=
  [ -n "$raw" ] && slug=$(fm_branch_slug "$raw")
  if [ -n "$slug" ]; then
    printf '%s\n' "$slug"
  else
    printf '%s\n' "fm/$id"
  fi
}

# fm_branch_from_meta <meta-file> <id>: echo the recorded branch= for a task, or the
# fm/<id> fallback when meta has no branch= line (in-flight tasks predating the field).
fm_branch_from_meta() {
  local meta=$1 id=$2 b=
  [ -f "$meta" ] && b=$(grep '^branch=' "$meta" | tail -1 | cut -d= -f2- || true)
  if [ -n "$b" ]; then
    printf '%s\n' "$b"
  else
    printf '%s\n' "fm/$id"
  fi
}
