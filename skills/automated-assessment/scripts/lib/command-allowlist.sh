#!/usr/bin/env bash
# command-allowlist.sh — the safety filter for checkpoint `type: command`
# patterns, shared by the runner and the authoring-time validator.
#
# Extracted from run-checkpoints.sh so validate-checkpoints.sh applies the
# EXACT rule the runner applies. A second, hand-copied implementation would
# drift, and a checkpoint that passes validation but is rejected at run time
# is worse than no validation: it reads as a check that runs.
#
# WHAT THIS FILTER IS, AND IS NOT (issue #71)
#
# It is NOT a sandbox, and it cannot be made into one. The allowlist admits
# general-purpose interpreters — `php -r`, `python3`, `node`, `awk`, `sed` —
# because installed checkpoints genuinely need them (`php -r "..."` reads
# composer.json, `python3 -m unittest` runs a suite, `awk 'BEGIN{...}'`
# compares versions). Any one of them executes arbitrary code:
# `awk 'BEGIN{system("...")}'` passes every check below. Removing them would
# break real checks across the installed skills; keeping them means a
# determined checkpoint author is not stopped by this file.
#
# The trust boundary is INSTALLATION. A skill you install already directs an
# agent through its SKILL.md; a checkpoint is not the weakest link in that
# chain. What this filter does is bound the BLAST RADIUS of a checkpoint that
# is careless rather than hostile — the sweep that would have deleted a tree,
# the `gh api` call that mutates the repo it was meant to inspect, the
# `./script` picked up from the project under assessment (which IS third-party
# code, and the one input here that is genuinely untrusted).
#
# So: keep the checks tight and fix the holes that are cheap to fix — a guard
# that is wrong is worse than none, and each hole found so far was a spelling
# no author would use by accident. But do not present this filter as
# containment, do not gate a security claim on it, and do not add a check
# whose only justification is stopping a malicious author: that one has
# `awk` and is already past you.
#
# KNOWN-OPEN, deliberately (all verified to execute; none is an accident
# shape, and every attempt to close them rejected legitimate checkpoints —
# a false reject silently disables a real check, which is the worse failure):
#
#   * Expansion splices other than $IFS: `xargs ${x:-rm} -rf dir`,
#     `xargs r${x}m -rf dir`, `xargs rm$1 -r dir`, `cat f | ${x:-sh}`.
#     Substituting expansions away and re-scanning catches these, and also
#     rejects `grep -rq 'rm${IFS}-rf' scripts/` — a checkpoint auditing a
#     project for this very trick — because bash does not expand inside
#     single quotes but a text substitution does not know that.
#   * Traversal spelled through an expansion: `.$1./evil` resolves to
#     `../evil` with no literal `..` anywhere in the text.
#   * A wrapper that takes its command after a value-bearing flag:
#     `timeout 5 ./x`, `nice -n 10 ./x`. The wrapper list itself cannot be
#     complete either.
#   * A shell reached through an allowlisted wrapper: `| env sh -c '...'`.
#     Requiring each pipe segment's command word to be on the whitelist
#     closes it and rejects `xargs -r -I {} test -e {}`, where `{}` is the
#     flag's value, not the command.
#
# Before "fixing" one of these, re-run tests/command-allowlist.sh AND the
# estate sweep it documents. Each entry above is a fix that was written,
# measured against real checkpoints, and reverted.
#
# Sourced, never executed.


# Fold a YAML *folded* block scalar body (`>` / `>-` / `>+`) into the single
# logical line YAML says it is.
#
# Lives here rather than in the runner because the authoring-time validator
# must screen the SAME text the runner executes: a folded body reaches
# is_safe_eval_command as one line, and a validator that folded differently
# would reach a different verdict on the same checkpoint.
#
# Rules implemented (YAML 1.2 §8.1.3, minus chomping, which only decides
# trailing newlines and cannot change what a command does):
#   * consecutive non-empty lines join with a single space
#   * a blank line is a real line break (n blank lines -> n newlines)
#   * a MORE-indented line is not folded — it keeps its own line, and the
#     breaks around it are kept too
#
# Folding is not cosmetic. `>-` over the two lines "grep -q foo" and
# "README.md" means `grep -q foo README.md`; preserving the newline instead
# would run `grep -q foo` with no file argument, which blocks on stdin.
# Input: the body with the block's base indentation already stripped.
fold_yaml_block() {
    local body="$1" line out="" first=1 pending=0 force_break=0 indented
    while IFS= read -r line; do
        if [[ -z "${line//[[:space:]]/}" ]]; then
            (( pending++ ))
            continue
        fi
        indented=0
        [[ "$line" == [[:space:]]* ]] && indented=1
        if (( first )); then
            out="$line"
            first=0
        elif (( pending > 0 )); then
            while (( pending > 0 )); do out+=$'\n'; (( pending-- )); done
            out+="$line"
        elif (( indented || force_break )); then
            out+=$'\n'"$line"
        else
            out+=" $line"
        fi
        force_break=$indented
        pending=0
    done <<<"$body"
    printf '%s' "$out"
}

# Remove every single/double quote from a word. Used where bash's own
# quote removal changes what a token MEANS — in command position, where
# `'./evil'` executes ./evil — never on arguments, where a quoted
# `'./vendor/*'` glob must stay distinguishable from an invocation.
# Split a pattern on `|` at TOP LEVEL only, one segment per line. A `|`
# inside quotes is data — a jq program, a grep alternation — not a
# pipeline separator, and splitting blind made `grep -E 'a|b/c'` look
# like a segment whose command word was `b/c`, rejecting real
# checkpoints. Patterns cannot contain a newline here (a multi-line
# scalar never reaches the runner as a command), so newline is a safe
# record separator.
split_top_level_pipes() {
    local s="$1" out="" c insq=0 indq=0 i bs
    bs=$'\\'
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        # Outside single quotes a backslash escapes the next character,
        # so the `'\''` idiom (close, literal quote, reopen) leaves the
        # state where it found it. Tracking this wrong flipped the state
        # mid-regex and split a `|` that was data — a real checkpoint
        # scanning for `(sk-|AKIA|ghp_)` was rejected for it.
        if (( ! insq )) && [[ "$c" == "$bs" ]]; then
            out+="$c${s:i+1:1}"
            (( i++ ))
            continue
        fi
        if (( ! indq )) && [[ "$c" == "'" ]]; then
            insq=$(( 1 - insq ))
        elif (( ! insq )) && [[ "$c" == '"' ]]; then
            indq=$(( 1 - indq ))
        fi
        if (( ! insq && ! indq )) && [[ "$c" == '|' ]]; then
            out+=$'\n'
        else
            out+="$c"
        fi
    done
    printf '%s' "$out"
}

strip_quotes() {
    local s="$1" _sq="'" _dq='"'
    s=${s//"$_sq"/}
    s=${s//"$_dq"/}
    printf '%s' "$s"
}

# Static screen for multi-line `type: script` checkpoint bodies.
#
# A multi-line body cannot pass is_safe_eval_command, and meaningfully so:
# that function's model — one base command word, operators as separators —
# describes a one-liner. `if`/`then`/`fi`, variable assignments and `$()`
# are not smuggling attempts; they are what a script IS. So a script gets
# the checks that still mean something on free-form text and skips the ones
# that do not:
#
#   kept:    the $IFS splice check and the dangerous-pattern regex
#            (curl|sh, sudo, rm -r, ...) — both are text-level signals
#            whose rationale does not depend on line count.
#   dropped: the whitelist (a script legitimately uses many commands),
#            the operator check (; && || ` $( are syntax here), the ./X
#            and path-prefix scans (a script may cd anywhere).
#
# This widens what an authoring-time checkpoint can do, and the file header
# already states why that is acceptable: the trust boundary is INSTALLATION,
# and the filter bounds blast radius of carelessness rather than containing
# malice. `type: script` is an explicit opt-in — an author writes it knowing
# it runs as a script — which is what separates it from a one-liner quietly
# growing semicolons until it stops being one.
# Returns 0 if safe, 1 if rejected (with reason on stdout).
is_safe_script_text() {
    local pattern="$1"

    local _outside_sq
    _outside_sq=$(printf '%s' "$pattern" | sed "s/'[^']*'//g")
    if [[ "$_outside_sq" =~ \$\{?IFS ]]; then
        echo "pattern splices words with \$IFS"
        return 1
    fi

    # Identical class list to is_safe_eval_command's dangerous-pattern regex,
    # minus the `\| sh` alternative's pipe spelling: inside a script,
    # `curl ... | sh` still matches via `curl.*\|.*sh`, and a bare pipeline
    # into sh on its own line has no pipe before it to match anyway.
    if [[ "$pattern" =~ (curl[[:space:]].*\|[[:space:]]*(ba)?sh|wget[[:space:]].*\|[[:space:]]*(ba)?sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R) ]]; then
        echo "contains dangerous pattern"
        return 1
    fi

    return 0
}

# Validate that a command is safe to eval.
# Uses a whitelist of allowed base commands and rejects dangerous patterns.
# Returns 0 if safe, 1 if rejected (with reason on stdout).
is_safe_eval_command() {
    local pattern="$1"
    # Strip a leading `!` (POSIX pipeline negation) so `! grep -q ...`
    # reaches whitelist evaluation as `grep`. awk's default field
    # splitter handles the leading whitespace introduced by the strip.
    local stripped="${pattern#!}"
    local cmd_base
    cmd_base=$(echo "$stripped" | awk '{print $1}')

    # The accepted command runs through `bash <<<`, which removes
    # backslashes during word expansion — so a `\`-escaped flag or path
    # separator reaches argv bare while never matching a
    # whitespace-anchored or substring check on the raw spelling: `\-X`,
    # `.\.` and `-\r` executed as `-X`, `..` and `-r` (issue #67). Every
    # argv- or path-level check below (dangerous patterns, `..`, `./X`)
    # therefore runs on the backslash-stripped text. Quotes are NOT
    # stripped here: a quoted `-path './vendor/*'` is a legitimate find
    # argument, and unquoting it would trip the `./X` guard. Operator
    # checks (`;`, `&&`, backtick, `$(`) stay on the raw pattern — bash
    # parses operators before expansion, so an expansion-produced `;` is
    # a literal argument, never a separator. The `gh` branch does its own
    # stronger normalization (see there), because a quoted flag `'-X'`
    # DOES reach gh as `-X` and there is no legitimate quoted glob in a
    # read-only `gh api` call.
    local normalized="$pattern" _bs
    _bs=$'\\'
    normalized=${normalized//"$_bs"/}

    # `$IFS` is the one expansion whose documented purpose is to produce
    # a word separator, and splicing it between the halves of a blocked
    # token reassembles that token after a literal-text check has passed:
    # `xargs rm${IFS}-r dir` word-splits into [rm][-r][dir] and deletes
    # the tree, `cat f |${IFS}sh` pipes into a shell (issue #69). Reject
    # it — and ONLY it. This is not a model of bash expansion and must
    # not be extended into one: `${x:-rm}`, `r${x}m` and `rm$1` splice
    # just as well, and the substitute-and-rescan approach that would
    # catch them mis-fires on legitimate patterns (see the header's
    # KNOWN-OPEN list). Single-quoted regions are exempt because bash
    # does not expand inside them: `grep -rq 'rm${IFS}-rf' scripts/` is a
    # checkpoint INSPECTING a project for this trick, and rejecting it
    # would silently disable a real check. Mis-pairing a `'` that is
    # itself inside double quotes only skips the check, never adds a
    # rejection.
    local _outside_sq
    _outside_sq=$(printf '%s' "$normalized" | sed "s/'[^']*'//g")
    if [[ "$_outside_sq" =~ \$\{?IFS ]]; then
        echo "pattern splices words with \$IFS"
        return 1
    fi

    # Whitelist of allowed base commands for checkpoint execution.
    # Includes shell control keywords + builtins — these don't execute
    # external commands themselves; the body still runs through the same
    # dangerous-pattern filter applied to the entire pattern string.
    local -a allowed_cmds=(
        grep egrep fgrep find test wc jq yq python3 python composer php
        phpstan phpcs phpcbf rector phpunit node npm cat head tail ls
        stat file diff sort uniq git make go sed awk tr cut xargs
        for if while case until '[' set printf echo true false
        gh
    )

    # Reject commands containing dangerous patterns regardless of base
    if [[ "$normalized" =~ (curl.*\|.*sh|wget.*\|.*sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R|\|[[:space:]]*(ba)?sh) ]]; then
        echo "contains dangerous pattern"
        return 1
    fi

    # Reject any `..` segment anywhere in the pattern. Path traversal
    # like `vendor/bin/../set` or `./vendor/bin/../../some-script` would
    # otherwise still match the `vendor/bin/*` allow-prefix below while
    # actually resolving outside vendor/bin.
    if [[ "$normalized" =~ \.\. ]]; then
        echo "pattern contains '..' path traversal"
        return 1
    fi

    # Reject command-chaining metacharacters that smuggle a second
    # command past the cmd_base check (`grep foo && ./set`,
    # `grep foo; ./set`, `grep foo \`./set\``, `grep foo $(./set)`).
    # We do NOT block `|` here — pipe chains like `grep foo | wc -l` are
    # idiomatic. Pipe stages still run through the per-token check
    # below for any `./X` that isn't `./vendor/bin/`.
    # shellcheck disable=SC2016  # the single quotes are the point: match a literal `$(`
    if [[ "$pattern" =~ (\;|\&\&|\|\||\`) || "$pattern" == *'$('* ]]; then
        echo "pattern contains command-chaining metacharacter (; && || \` \$())"
        return 1
    fi

    # Scan the entire pattern for any whitespace-separated `./X` token
    # that is NOT `./vendor/bin/...`. This catches a `./X` invocation
    # buried after a pipe, file redirection, etc. — locations that
    # cmd_base does not reach.
    # `set -f` for both scans below: an unquoted expansion of the pattern
    # is word splitting, which is wanted, AND pathname expansion, which
    # is not — with globbing live, `e* './evil'` resolved against the
    # working directory, so the validator (author's cwd) and the runner
    # (assessed project's cwd) could reach OPPOSITE verdicts on one
    # pattern. That divergence is the failure this file exists to
    # prevent.
    local _reset_f=1
    [[ $- == *f* ]] || { set -f; _reset_f=0; }

    local tok
    for tok in $normalized; do
        if [[ "$tok" == ./* && "$tok" != ./vendor/bin/* ]]; then
            (( _reset_f )) || set +f
            echo "pattern contains './${tok#./}'; only ./vendor/bin/* is allowed"
            return 1
        fi
    done

    # The scan above deliberately leaves quotes on, so that a quoted
    # `-path './vendor/*'` find ARGUMENT is not read as a `./X`
    # invocation. In command position the quotes carry no such meaning:
    # bash removes them and executes the word, so `grep x | './evil'`
    # ran ./evil while the quoted token slipped the scan (issue #70).
    # So: locate the command word of every `|` segment and check THAT
    # with quotes removed. `&&`/`||`/`;` need no handling — they are
    # rejected above, leaving `|` as the only separator that can start a
    # new command.
    #
    # The wrapper list cannot be complete, and a wrapper that takes its
    # command after a VALUE-bearing flag (`timeout 5 ./x`, `nice -n 10
    # ./x`) still hides it. See the header's KNOWN-OPEN list.
    local -a _cmd_takers=(xargs env nohup timeout watch command nice stdbuf setsid ionice chrt taskset flock)
    local _seg _t _bare _taker _cw _i
    local -a _segs _toks
    # Split the RAW pattern, not the backslash-stripped one: the quote
    # tracker needs the backslashes to recognise an escaped quote.
    # Newlines first — they are the segment separator below.
    local _flat="${pattern//$'\n'/ }"
    mapfile -t _segs < <(split_top_level_pipes "$_flat")
    for _seg in "${_segs[@]}"; do
        # shellcheck disable=SC2206  # word splitting is the point; globbing is off
        _toks=(${_seg#!})
        _taker=false
        for (( _i = 0; _i < ${#_toks[@]}; _i++ )); do
            _bare=$(strip_quotes "${_toks[_i]}")
            _bare=${_bare//"$_bs"/}
            # Leading redirections and VAR=value assignments precede the
            # command word; bash allows both, so skip past them rather
            # than mistaking one for the command (`| >out './evil'`).
            [[ "$_bare" == *'>'* || "$_bare" == '<'* ]] && continue
            [[ "$_bare" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
            # A wrapper's own flags are not the wrapped command either.
            $_taker && [[ "$_bare" == -* ]] && continue
            _cw="$_bare"
            if [[ "$_cw" == ./* && "$_cw" != ./vendor/bin/* ]]; then
                (( _reset_f )) || set +f
                echo "pattern executes './${_cw#./}' in command position; only ./vendor/bin/* is allowed"
                return 1
            fi
            # `$'...'`/`$"..."` can spell a command word in bytes that
            # quote removal does not reproduce; the gh branch rejects
            # this class outright and command position is no different.
            if [[ "${_toks[_i]}" == *'$'\'* || "${_toks[_i]}" == *'$"'* ]]; then
                (( _reset_f )) || set +f
                echo "pattern spells a command word with \$'...'/\$\"...\" quoting"
                return 1
            fi
            # `cmd_base` applies the whitelist to the pattern's FIRST
            # word only, so `grep x | scripts/evil` and `| /bin/dash`
            # ran a command the same rule forbids in first position.
            # Same rule, every command word.
            if [[ "$_cw" != vendor/bin/* && "$_cw" != ./vendor/bin/* && "$_cw" == */* ]]; then
                (( _reset_f )) || set +f
                echo "'$_cw' has path prefix; only vendor/bin/* (with optional ./) is allowed"
                return 1
            fi
            if ! $_taker; then
                for _t in "${_cmd_takers[@]}"; do
                    [[ "$_cw" == "$_t" ]] && _taker=true && break
                done
                # A wrapper's wrapped command is the next command word;
                # anything else ends this segment's command position.
                $_taker && continue
            fi
            break
        done
    done
    (( _reset_f )) || set +f

    # Allow vendor/bin/* paths (with or without leading `./`). Anything
    # else with a path component is rejected — checkpoints may not
    # invoke `./foo` style scripts. The previous `sed 's|^\./||'`
    # normalisation let `./set` (a repo-local script) pass the
    # whitelist by matching the `set` shell-builtin entry.
    if [[ "$cmd_base" == vendor/bin/* || "$cmd_base" == ./vendor/bin/* ]]; then
        return 0
    fi

    if [[ "$cmd_base" == */* ]]; then
        echo "'$cmd_base' has path prefix; only vendor/bin/* (with optional ./) is allowed"
        return 1
    fi

    for acmd in "${allowed_cmds[@]}"; do
        if [[ "$cmd_base" == "$acmd" ]]; then
            # Restrict `gh` to read-only API queries. An assessment runs
            # with the operator's gh credentials against the repo under
            # assessment, so a checkpoint that reaches for a mutating
            # subcommand (`gh repo edit`, `gh release delete`, `gh api
            # -X DELETE ...`) writes to a real repo — the highest-blast-
            # radius accident available here. Not containment (see the
            # file header): a checkpoint can still shell out via an
            # allowlisted interpreter.
            #
            # Allowed shape: `gh api <endpoint>` with no explicit
            # state-changing method (`-X POST|PUT|PATCH|DELETE` /
            # `--method ...`) and no `--input`/`-f`/`-F` request-body
            # flags. `gh api` defaults to GET, so a bare `gh api` call
            # is safe.
            if [[ "$cmd_base" == "gh" ]]; then
                local _gh_sub
                _gh_sub=$(echo "$stripped" | awk '{print $2}')
                if [[ "$_gh_sub" != "api" ]]; then
                    echo "'gh $_gh_sub' is not allowed; only 'gh api' (read-only) is permitted"
                    return 1
                fi
                # The flag checks run on a MORE aggressively normalized
                # form than the general checks: a quoted `'-X'` or `"-X"`
                # reaches gh as a bare `-X` (bash removes the quotes), so
                # the quotes come out here too. That is safe in a
                # read-only `gh api` call, whose arguments are an
                # endpoint, flags and a --jq filter — never a quoted
                # filesystem glob that the general `./X` guard protects.
                # $'...'/$"..." quoting can still synthesize `-X` from
                # escapes that no strip reproduces (`$'\055X'`); reject it
                # as a class here, where it has no legitimate use.
                local _gh="$normalized" _sq="'" _dq='"'
                _gh=${_gh//"$_sq"/}
                _gh=${_gh//"$_dq"/}
                if [[ "$_gh" == *'$'* ]]; then
                    echo "'gh api' rejected: '\$' (shell/ANSI-C quoting) not allowed in a read-only api call"
                    return 1
                fi
                # Reject ANY method flag, in any spelling. gh accepts the
                # value spaced (`-X DELETE`), glued (`-XDELETE`) or with
                # `=`, so match the flag alone rather than the flag+verb —
                # `-XGET` glued would otherwise slip a space-anchored
                # verb check (issue #67 follow-up). `gh api` defaults to
                # GET and no read-only flag begins `-X`/`--method`, so a
                # bare match is safe; the estate uses no method flag.
                if [[ "$_gh" =~ (^|[[:space:]])(-X|--method)([[:space:]]|=|[A-Za-z]) ]]; then
                    echo "'gh api' rejected: explicit method flag (-X/--method) not allowed; api defaults to GET"
                    return 1
                fi
                # Reject ANY request-body flag, in any spelling. These
                # switch gh api to POST. `-f`/`-F` are the short forms of
                # `--raw-field`/`--field`; cover the long aliases and the
                # glued short form (`-fa=b`) the previous space/`=`-anchored
                # check missed. No read-only flag begins `-f`/`-F`.
                if [[ "$_gh" =~ (^|[[:space:]])(--input|--field|--raw-field|-f|-F) ]]; then
                    echo "'gh api' rejected: request-body flags (--input/--field/--raw-field/-f/-F) are not allowed"
                    return 1
                fi
            fi
            return 0
        fi
    done

    echo "'$cmd_base' not in allowed command whitelist"
    return 1
}
