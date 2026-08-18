#!/usr/bin/env bash
# tests/command-allowlist.sh — unit-tests is_safe_eval_command directly.
#
# The allowlist's argv- and path-level checks (gh flags, `..`, `./X`,
# `rm -r`) match TEXT, but the accepted command runs through `bash <<<`,
# which strips backslashes and quotes during word expansion. A spelling
# like `\-X` or '-X' therefore executed as a bare -X while never matching
# a whitespace-anchored regex — issue #67. These tests pin the verdict
# for each spelling of the same argv, accepted and rejected alike.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091  # path is built at runtime from the test's own location
source "$ROOT/skills/automated-assessment/scripts/lib/command-allowlist.sh"

fail=0
verdict() { # verdict <expected accept|reject> <pattern>
    local expected="$1" pattern="$2" got
    if is_safe_eval_command "$pattern" > /dev/null; then got=accept; else got=reject; fi
    if [ "$expected" = "$got" ]; then
        echo "  ok   $expected: $pattern"
    else
        echo "  FAIL expected $expected, got $got: $pattern"
        fail=1
    fi
}

echo "command-allowlist.sh"

# --- baseline verdicts that must not move ------------------------------------
verdict accept 'grep -q pattern README.md'
verdict accept 'find . -name "*.php" | wc -l'
verdict accept 'gh api repos/netresearch/automated-assessment-skill'
verdict accept 'gh api repos/o/r --jq .name'
verdict reject 'gh api repos/o/r -X DELETE'
verdict reject 'gh api repos/o/r --method=POST'
verdict reject 'gh api repos/o/r --input body.json'
verdict reject 'gh repo delete o/r'
# shellcheck disable=SC2016  # the literal $( is the point: it must be rejected, not expanded
verdict reject 'test -z "$(ls)"'
verdict reject 'cat ../secret'
verdict reject './run.sh'

# --- issue #67: expansion-resistant spellings of rejected argv ---------------
# bash <<< strips the backslash/quotes, so each of these executes exactly
# like its rejected twin above.
verdict reject 'gh api repos/o/r \-X DELETE'
verdict reject "gh api repos/o/r '-X' DELETE"
verdict reject 'gh api repos/o/r "-X" DELETE'
verdict reject 'gh api repos/o/r \--method POST'
verdict reject 'gh api repos/o/r \-f a=b'
verdict reject 'cat .\./secret'
verdict reject 'echo .\/run.sh'
verdict reject 'xargs rm -\r x'

# $'..' / $".." quoting can synthesize argv bytes (e.g. $'\055X' is -X)
# that no backslash/quote strip reproduces — rejected as a class.
verdict reject "gh api repos/o/r \$'\\055X' DELETE"
verdict reject 'gh api repos/o/r $"-X" DELETE'

# gh accepts a short-flag value glued to the flag (`-XDELETE`) or via `=`;
# match the flag itself, not flag+verb, so no spelling of an explicit
# method reaches gh (issue #67 follow-up — verified accepted pre-hardening).
verdict reject 'gh api repos/o/r -XDELETE'
verdict reject 'gh api repos/o/r -XPOST'
verdict reject 'gh api repos/o/r -X=PATCH'
verdict reject 'gh api repos/o/r --method PUT'
# Request-body flags switch gh api to POST — long aliases and glued short
# forms included (`--field`/`--raw-field` are the long forms of `-F`/`-f`).
verdict reject 'gh api repos/o/r --field a=b'
verdict reject 'gh api repos/o/r --raw-field a=b'
verdict reject 'gh api repos/o/r -fa=b'
verdict reject 'gh api repos/o/r -Fa=b'
# A read-only endpoint with a query string that merely contains letters
# after a dash must still be accepted — the method guard keys on `-X` at a
# word boundary, not any dash.
verdict accept 'gh api search/issues?q=is:open --jq length'

# --- issue #69: expansion reconstructs a blocked token ----------------------
# `bash <<<` expands and word-splits before argv exists, so an expansion
# between two halves of a blocked token defeats a check that reads the
# literal text. Blocked-token checks therefore also run on a form where
# every expansion is replaced by a space.
# shellcheck disable=SC2016  # literal ${IFS} is the attack; it must not expand here
verdict reject 'xargs rm${IFS}-r victimdir'
# shellcheck disable=SC2016
verdict reject 'grep x | ${IFS}./evil'
# shellcheck disable=SC2016
verdict reject 'cat f |${IFS}sh'
# shellcheck disable=SC2016
verdict reject 'find . -name x -exec${IFS}sh -c evil +'
# A legitimate expansion stays accepted — the rule may not reject `$` or
# `${` as a class. Both shapes below occur in installed checkpoints.
# shellcheck disable=SC2016
verdict accept '[ "$missing" -eq 0 ]'
# shellcheck disable=SC2016
verdict accept 'grep -LP default "$f" 2>/dev/null'
# A `$` that is not an expansion (regex end-anchor) must not be touched.
verdict accept "grep -rqF 'echo \$' --include='*.php' Classes/"

# --- issue #70: quoted ./script in command position -------------------------
# A quoted token keeps its quotes through the general checks so that a
# legitimate `-path './vendor/*'` find argument is not read as a `./X`
# invocation. That leaves the command position, where the quotes come off.
verdict reject "grep x | './evil'"
verdict reject 'grep x | "./evil"'
verdict reject "'./evil'"
verdict reject "! './evil'"
# A command-taking command's first non-flag argument is a command too.
verdict reject "grep -rl x . | xargs './evil'"
verdict reject 'grep -rl x . | xargs "./evil"'
# The estate's quoted glob arguments must survive untouched.
verdict accept "find . -name '*.go' -not -path './vendor/*' | head -1 | grep -q ."
verdict accept "find . -path '*/SKILL.md' -not -path './node_modules/*' | head -1 | grep -q ."
verdict accept './vendor/bin/phpstan analyse'

# Quote/backslash stripping must not manufacture false accepts either:
# a genuinely harmless quoted argument keeps its verdict.
verdict accept "grep -q 'a b c' README.md"

echo
if [ "$fail" -eq 0 ]; then
    echo "All command-allowlist tests passed"
else
    echo "Some command-allowlist tests FAILED"
fi
exit "$fail"
