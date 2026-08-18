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
EOF

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
check "a refused pattern fails"          fail "$(status_of DM-04)"
check "YAML \\\" in dq pattern decoded"    pass "$(status_of DM-05)"
check "YAML \\\\ in dq pattern decoded"    pass "$(status_of DM-06)"
check "the refusal names the reason" yes \
    "$(jq -r '.checkpoints[] | select(.id=="DM-04") | .evidence' <<<"$out" | grep -q 'command-chaining metacharacter' && echo yes || echo no)"

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
