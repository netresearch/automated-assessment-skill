#!/usr/bin/env bash
# tests/checkpoint-validation.sh — covers validate-checkpoints.sh, the script
# two reference docs told authors to run while it did not exist.
#
# The cases that matter are the ones that make a checkpoint silently not run:
# a multi-line YAML scalar (the runner parses line by line and receives the
# literal `|-`), and a pattern the runner's allowlist rejects. Both shipped in
# the wild — git-workflow's GW-15 and GW-16 are rejected outright, and GW-17
# was written the same way until this check found it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VALIDATOR="$ROOT/skills/automated-assessment/scripts/validate-checkpoints.sh"
RUNNER="$ROOT/skills/automated-assessment/scripts/run-checkpoints.sh"
LIB="$ROOT/skills/automated-assessment/scripts/lib/command-allowlist.sh"
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

# cp_file <name> <mechanical-body>
cp_file() {
    local f="$WORK/$1.yaml"
    { printf 'version: 1\nskill_id: demo\n\nmechanical:\n'; cat; } > "$f"
    echo "$f"
}

echo "validate-checkpoints.sh"

# --- 1. a well-formed file passes -------------------------------------------
f=$(cp_file good <<'EOF'
  - id: DM-01
    type: file_exists
    target: README.md
    severity: error
    desc: "README must exist"
  - id: DM-02
    type: command
    pattern: "git cat-file commit HEAD | grep -q tree"
    severity: info
    desc: "HEAD is a commit"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a well-formed file passes" 0 "$rc"
check "it reports the checkpoint count" yes "$(grep -q '2 mechanical checkpoint(s) validated' <<<"$out" && echo yes || echo no)"

# --- 2. a multi-line scalar never reaches the runner as a command -----------
f=$(cp_file blockscalar <<'EOF'
  - id: DM-03
    type: command
    pattern: |-
      test -z "$(git status --porcelain)"
    severity: error
    desc: "clean tree"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a multi-line pattern is an error" 1 "$rc"
check "the message names the cause" yes \
    "$(grep -q "DM-03: 'pattern' is a multi-line YAML scalar" <<<"$out" && echo yes || echo no)"

# --- 3. a pattern the runner's allowlist rejects ----------------------------
f=$(cp_file chained <<'EOF'
  - id: DM-04
    type: command
    pattern: 'test -z "$(git ls-files -- docs/)"'
    severity: warning
    desc: "no docs tracked"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a chaining metacharacter is an error" 1 "$rc"
check "the runner's own reason is quoted" yes \
    "$(grep -q 'command-chaining metacharacter' <<<"$out" && echo yes || echo no)"

# --- 4. structural checks the schema documents ------------------------------
f=$(cp_file structural <<'EOF'
  - id: DM-05
    type: nonsense
    target: x
    severity: error
    desc: "bogus type"
  - id: DM-05
    type: contains
    target: README.md
    severity: sometimes
    desc: "duplicate id, bad severity, missing pattern"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "structural problems are errors" 1 "$rc"
check "an unknown type is reported"      yes "$(grep -q "unknown type 'nonsense'" <<<"$out" && echo yes || echo no)"
check "a duplicate id is reported"       yes "$(grep -q 'duplicate checkpoint id(s): DM-05' <<<"$out" && echo yes || echo no)"
check "an invalid severity is reported"  yes "$(grep -q "invalid severity 'sometimes'" <<<"$out" && echo yes || echo no)"
check "a missing required field is reported" yes \
    "$(grep -q "requires 'pattern'" <<<"$out" && echo yes || echo no)"

# --- 5. llm_reviews entries are not treated as mechanical -------------------
f="$WORK/llm.yaml"
cat > "$f" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-06
    type: file_exists
    target: README.md
    severity: info
    desc: "README"

llm_reviews:
  - id: DM-20
    domain: demo
    prompt: |
      test -z "$(git status)"
    severity: info
    desc: "subjective"
EOF
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "an llm_reviews prompt is not validated as a command" 0 "$rc"

# --- 6. one implementation, not two ----------------------------------------
# The validator must apply the runner's rule, not a copy of it: a copy drifts,
# and a checkpoint that passes validation but is rejected at run time is worse
# than no validation at all.
check "the runner sources the shared allowlist" yes \
    "$(grep -q 'source .*lib/command-allowlist.sh' "$RUNNER" && echo yes || echo no)"
check "the validator sources the shared allowlist" yes \
    "$(grep -q 'source .*lib/command-allowlist.sh' "$VALIDATOR" && echo yes || echo no)"
check "the allowlist is defined exactly once" 1 \
    "$(grep -rc '^is_safe_eval_command() {' "$LIB" "$RUNNER" "$VALIDATOR" | awk -F: '{s+=$2} END {print s}')"

echo
if [ "$fail" -eq 0 ]; then
    echo "All checkpoint-validation tests passed"
else
    echo "Some checkpoint-validation tests FAILED"
fi
exit "$fail"
