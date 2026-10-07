#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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

# --- command_base_word: the word both the allowlist and the runner's ---------
# missing-executable check (issue #96) treat as the program being run.
base_word() { # base_word <expected> <pattern>
    local got
    got=$(command_base_word "$2")
    if [ "$1" = "$got" ]; then
        echo "  ok   base word '$1': $2"
    else
        echo "  FAIL base word expected '$1', got '$got': $2"
        fail=1
    fi
}
base_word 'vendor/bin/validate-pre-release.sh' 'vendor/bin/validate-pre-release.sh --version-sync-only 2>/dev/null'
base_word 'grep' '! grep -q x README.md'
base_word 'grep' '  grep -q x README.md'
base_word 'find' 'find . -name "*.php" | wc -l'

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
# The read-only rule holds wherever gh is a command word, not only first:
# after a pipe, and behind a wrapper such as xargs. Both mutating shapes
# were accepted while the rule looked at the pattern's first word only.
verdict reject 'grep -q x README.md | gh repo edit --visibility public'
verdict reject 'echo x | xargs gh release delete v1 --yes'
verdict reject 'xargs gh repo delete o/r'
verdict reject 'echo repos/o/r | xargs gh api -X DELETE'
verdict reject "echo repos/o/r | xargs gh api '-X' DELETE"
verdict reject 'echo repos/o/r | xargs gh api --input body.json'
verdict accept 'echo repos/o/r | xargs gh api --jq .name'
verdict accept 'gh api repos/o/r --jq .name | grep -q x'
# A wrapper behind a wrapper: the second one used to end the scan, so the
# command it wraps was never checked.
verdict reject 'xargs env gh repo edit'
verdict reject 'echo x | nohup env gh repo delete o/r'
verdict reject 'echo x | xargs env gh api -X DELETE repos/o/r'
verdict reject 'xargs env scripts/evil'
verdict reject 'echo x | env nohup scripts/evil'
verdict accept 'echo repos/o/r | xargs env gh api --jq .name'
# find -execdir runs a command like -exec does; the dangerous-pattern
# regex matched only `exec ` and let `-execdir ` through.
verdict reject 'find . -maxdepth 0 -execdir gh repo edit {} +'
verdict reject 'find . -maxdepth 0 -execdir scripts/x {} +'
# -i is gh api's one boolean short flag; a method or body flag glued behind
# it (-iXDELETE, -if) still reaches gh.
verdict reject 'gh api -iXDELETE repos/o/r/git/refs/heads/x'
verdict reject 'gh api -iX DELETE repos/o/r'
verdict reject 'gh api -if name=x repos/o/r'
verdict reject 'grep -q x f | gh api -iX DELETE repos/o/r'
verdict accept 'gh api -i repos/o/r'
# A single & ends a command like ; does, and |& pipes into the next one;
# redirections and a quoted & are not separators.
verdict reject 'grep -q x f & gh repo edit o/r'
verdict reject 'grep -q x f & scripts/x'
verdict reject 'grep -q x f |& gh repo edit o/r'
verdict accept 'grep -q x f 2>&1'
verdict accept 'grep -q x f &>/dev/null'
verdict accept 'grep -q "GmbH & Co. KG" README.md'
verdict accept 'gh api "repos/o/r/actions/runs?status=success&per_page=1"'
# A subshell opener in front of gh hid it from the gh rule.
verdict reject 'grep -q x f | (gh repo delete o/r --yes)'
# Brace expansion assembles a method or body flag after the text check.
verdict reject 'gh api repos/o/r/x {-X,DELETE}'
verdict reject 'gh api repos/o/r/x {-f,a=b}'
verdict reject 'grep -q x f | gh api repos/o/r {-X,DELETE}'
verdict accept 'gh api repos/{owner}/{repo} --jq .name'

# --- issue #69: $IFS splices a blocked token back together ------------------
# `bash <<<` expands and word-splits before argv exists, so $IFS between
# the halves of a blocked token reassembles it after a literal-text check
# has passed. Verified: the first one deletes the directory.
# shellcheck disable=SC2016  # literal ${IFS} is the attack; it must not expand here
verdict reject 'xargs rm${IFS}-r victimdir'
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict reject 'grep x | ${IFS}./evil'
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict reject 'cat f |${IFS}sh'
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict reject 'find . -name x -exec${IFS}sh -c evil +'
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict reject 'cat f |$IFS sh'
# A legitimate expansion stays accepted — the rule may not reject `$` or
# `${` as a class. Both shapes below occur in installed checkpoints.
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict accept '[ "$missing" -eq 0 ]'
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict accept 'grep -LP default "$f" 2>/dev/null'
# A `$` that is not an expansion (regex end-anchor) must not be touched.
verdict accept "grep -rqF 'echo \$' --include='*.php' Classes/"
# Single-quoted text is not expanded by bash, so a checkpoint that
# SEARCHES a project for this very trick must still run. Rejecting it
# would silently disable a real check — the failure mode that motivated
# issue #52.
verdict accept "grep -rq 'rm\${IFS}-rf' scripts/"
# shellcheck disable=SC2016  # the literal $ is the test input; it must not expand
verdict accept 'grep -rq "$dir./sub" .'

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
verdict reject "grep x f | env './evil'"
# Redirections may precede the command word; they are not it.
verdict reject "grep x f | >out './evil'"
verdict reject "grep x f | 2>/dev/null './evil'"
# ANSI-C quoting spells a command word in bytes quote removal misses.
verdict reject "grep x f | \$'./evil'"
# Only the WRAPPED command is in command position — the wrapper's other
# arguments are data. Rejecting them silently disabled real checks.
verdict accept "git ls-files '*.php' | xargs grep -l './vendor/autoload.php'"
verdict accept "find . -name '*.yml' | xargs -I{} grep -q './bin' {}"
verdict accept "git ls-files | xargs grep -l -- './node_modules'"
# The estate's quoted glob arguments must survive untouched.
verdict accept "find . -name '*.go' -not -path './vendor/*' | head -1 | grep -q ."
verdict accept "find . -path '*/SKILL.md' -not -path './node_modules/*' | head -1 | grep -q ."
verdict accept './vendor/bin/phpstan analyse'
verdict accept "find . -type f | xargs ./vendor/bin/phpcs"

# Quote/backslash stripping must not manufacture false accepts either:
# a genuinely harmless quoted argument keeps its verdict.
verdict accept "grep -q 'a b c' README.md"

# `cmd_base` applies the whitelist to the FIRST word only; a pipe used
# to start a second command must obey the same rule.
verdict reject 'grep -q x f | scripts/evil'
verdict reject 'grep -q x f | /bin/dash'
verdict reject 'grep x f | .\/evil'

# --- a `|` inside quotes is data, not a pipeline separator ------------------
# Splitting blind read a grep alternation or a jq program as segments and
# rejected real checkpoints. The last one uses the `'\''` idiom, where a
# naive quote tracker flips state mid-regex.
verdict accept "grep -qE 'foo|bar/baz' file"
verdict accept 'jq -e "[.a // {}] | add | to_entries[] | select(.k == \"x\")" composer.json'
verdict accept "grep -rqE '(api_key|token)[:=][\"'\\''](sk-|AKIA|ghp_)' SKILL.md"
verdict accept "grep -oP 'x' AGENTS.md | xargs -r -I {} test -e {}"

# --- every command word is classified, or the pattern is refused -----------
# The whitelist used to apply to the pattern's first word only: any command
# after a pipe ran unless it carried a path. Each pair below is a refused
# spelling and the legitimate shape next to it that must keep running.
verdict reject 'grep -q x f | zsh -c id'
verdict reject 'grep -q x f | perl -e 1'
verdict reject 'grep -q x f | time scripts/x'
verdict reject 'grep -q x f | coproc gh repo delete o/r'
verdict accept 'grep -q x f | wc -l'
verdict reject 'grep -q x f | env sh -c id'
verdict accept 'echo repos/o/r | xargs env gh api --jq .name'
# A wrapper's options are parsed with that wrapper's grammar, so the word it
# runs is found behind a value-taking flag or a duration.
verdict reject 'grep -q x f | xargs -n 1 scripts/x'
verdict reject 'grep -q x f | xargs -n1 gh repo delete o/r'
verdict reject 'grep -q x f | xargs --max-args 1 scripts/x'
verdict reject 'grep -q x f | timeout 5 scripts/x'
verdict reject 'grep -q x f | timeout -s KILL 5 gh repo delete o/r'
verdict reject 'grep -q x f | nice -n 5 zsh'
verdict accept 'grep -q x f | xargs -n 1 grep -l y'
verdict accept 'grep -q x f | timeout 5 grep -q y f'
verdict accept 'find . -name x -print0 | xargs -0 -r grep -lZE y'
verdict accept 'grep -oP x AGENTS.md | xargs -r -I {} test -e {}'
verdict accept 'grep -oP x AGENTS.md | xargs -r -I{} test -e {}'
# An option outside a wrapper's grammar, or a wrapper with no grammar here,
# cannot be classified and is refused.
verdict reject 'grep -q x f | xargs --no-such-option grep y'
verdict reject 'grep -q x f | xargs -Z grep -q y'
verdict reject 'grep -q x f | env -S "sh -c id"'
verdict reject 'grep -q x f | watch -n 1 grep y f'
# A quoted value holding a blank is one word, as bash reads it: it cannot pass
# for an option value followed by a whitelisted command.
verdict reject 'grep -q x f | xargs -I "a grep" scripts/x'
verdict reject 'grep -q x f | > "a grep" scripts/x'
verdict reject 'grep -q x f | env -u "A grep" scripts/x'
verdict reject 'grep x f | xargs -I "a grep" gh repo delete o/r'
verdict reject 'xargs -I "a grep" scripts/x'
verdict accept 'grep -q "a b" f | wc -l'
verdict accept "find . -name '*.yml' | xargs -I{} grep -q 'a b' {}"
# xargs --eof, --replace and --max-lines take a value only after `=`.
verdict reject 'find . -name x | xargs --eof scripts/x grep -q y'
verdict reject 'find . -name x | xargs --replace scripts/x grep -q y'
verdict reject 'find . -name x | xargs --max-lines scripts/x grep -q y'
verdict accept 'find . -name x | xargs --eof=END grep -q y'
verdict accept 'find . -name x | xargs --replace grep -q y'
# Assignments and redirections are recognised on the word as written; an
# assignment only before the segment's first command word.
verdict reject 'grep -q x f | "A=b"/x'
verdict reject 'find . -name x | xargs A=b/x'
verdict reject 'grep -q x f | timeout 5 A=b/x'
verdict reject "find . -name x | xargs '>'d/x"
verdict accept 'grep -q x f | LC_ALL=C grep -q y'
# A redirection is not part of argv wherever it stands, also between a
# wrapper's option and its value.
verdict reject 'find . -name x | xargs -I > grep grep scripts/x'
verdict reject 'grep -q x f | timeout > grep 5 scripts/x'
verdict reject 'grep -q x f | xargs -I 2>grep grep scripts/x'
verdict accept 'grep -q x f | xargs -n 1 2>/dev/null grep -q y'
# Redirections in front of the command word, numbered and spaced included.
verdict reject "grep -q x f | 3<f './evil'"
verdict reject 'grep -q x f | 0<f scripts/evil'
verdict reject 'grep -q x f | < f gh repo delete o/r'
verdict reject 'grep -q x f | 2> err scripts/evil'
verdict accept 'grep -q x f | 0<f grep -q y'
verdict accept 'grep -q x f | 2> err grep -q y'
# A process substitution runs its body as a command of its own.
verdict reject 'cat <(scripts/x)'
verdict reject 'grep -q x <(./evil)'
verdict reject 'diff <(gh repo delete o/r) f'
verdict reject 'cat <(grep -q x f | zsh)'
verdict reject 'cat <(grep -q x f'
verdict accept "cat <(find . -name x -print 2>/dev/null) <(grep -RlE 'a|b' .github/ 2>/dev/null) | grep -q ."
verdict accept "grep -q '<(x)' f"
# $'...' and $"..." quoting anywhere outside quotes: the bytes that run are
# not the bytes the checks read.
verdict reject "xargs rm \$'-r' dir"
verdict reject "xargs rm \$'\\055r' dir"
verdict reject 'grep -q x f | xargs rm $"-r" dir'
verdict reject "find . -name x \$'-exec' sh -c id {} +"
verdict reject "find . -name x \"\${x:-\$'\\055exec'}\" sh -c id {} +"
verdict accept "grep -q '\$'\"'\"'x' f"
verdict accept 'grep -q "foo$" f'
verdict accept "grep -rq 'echo \$\"x' ."
# Brace expansion builds words after the checks have read the text.
verdict reject 'xargs r{m,} -r dir'
verdict reject 'xargs {rm,-rf} dir'
verdict reject 'find . -name x {-exec,sh,-c,id,+}'
verdict reject 'grep -q x f | xargs {gh,repo,delete,o/r}'
verdict accept "grep -qE 'a{1,3}' f"
verdict accept 'gh api repos/{owner}/{repo} --jq .name'
verdict accept 'jq -e "[.a // {}, .b // {}] | add" composer.json'

# --- the verdict may not depend on the working directory --------------------
# Tokenizing with globbing live made `e* './evil'` resolve against the
# cwd, so validate-checkpoints.sh (author's cwd) and run-checkpoints.sh
# (assessed project's cwd) could disagree about one pattern — the exact
# divergence this shared file exists to prevent.
cwd_probe() { # cwd_probe <dir> <pattern>
    ( cd "$1" && if is_safe_eval_command "$2" > /dev/null; then echo accept; else echo reject; fi )
}
PROBE="$(mktemp -d)"
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/bare" "$PROBE/baited"
: > "$PROBE/baited/env"
for _p in "grep -q x f | e* './evil'" "grep -q x f | ./evil" "grep -q x f | 'e'*"; do
    _a=$(cwd_probe "$PROBE/bare" "$_p")
    _b=$(cwd_probe "$PROBE/baited" "$_p")
    if [ "$_a" = "$_b" ]; then
        echo "  ok   cwd-independent ($_a): $_p"
    else
        echo "  FAIL cwd-dependent verdict ($_a vs $_b): $_p"
        fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All command-allowlist tests passed"
else
    echo "Some command-allowlist tests FAILED"
fi
exit "$fail"
