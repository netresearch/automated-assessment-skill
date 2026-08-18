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
# Sourced, never executed.


# Remove every single/double quote from a word. Used where bash's own
# quote removal changes what a token MEANS — in command position, where
# `'./evil'` executes ./evil — never on arguments, where a quoted
# `'./vendor/*'` glob must stay distinguishable from an invocation.
strip_quotes() {
    local s="$1" _sq="'" _dq='"'
    s=${s//"$_sq"/}
    s=${s//"$_dq"/}
    printf '%s' "$s"
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

    # Second normalization, for the same reason one step later in bash's
    # order of operations: expansion happens before argv exists, and it
    # word-splits. An expansion placed between the halves of a blocked
    # token reassembles it after a literal-text check has already passed
    # — `xargs rm${IFS}-r dir` runs `rm -r dir`, `cat f |${IFS}sh` pipes
    # into a shell (issue #69). Replacing every expansion with a space
    # yields the token boundaries bash will produce, so the blocked-token
    # checks below run on that form as well as the literal one. `${` is
    # NOT rejected as a class: installed checkpoints use `"$f"` and
    # `${f#Classes/}` legitimately, and a `$` that is not an expansion
    # (a regex end-anchor, as in `grep -F 'echo $'`) is left alone.
    local expanded
    expanded=$(printf '%s' "$normalized" | sed -E 's/\$\{[^}]*\}/ /g; s/\$[A-Za-z_][A-Za-z0-9_]*/ /g')

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
    local _form
    for _form in "$normalized" "$expanded"; do
        if [[ "$_form" =~ (curl.*\|.*sh|wget.*\|.*sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R|\|[[:space:]]*(ba)?sh) ]]; then
            echo "contains dangerous pattern"
            return 1
        fi
    done

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
    local tok
    for tok in $normalized $expanded; do
        if [[ "$tok" == ./* && "$tok" != ./vendor/bin/* ]]; then
            echo "pattern contains './${tok#./}'; only ./vendor/bin/* is allowed"
            return 1
        fi
    done

    # The scan above deliberately leaves quotes on, so that a quoted
    # `-path './vendor/*'` find ARGUMENT is not read as a `./X`
    # invocation. In command position the quotes carry no such meaning:
    # bash removes them and executes the word, so `grep x | './evil'`
    # ran ./evil while the quoted token slipped the scan (issue #70).
    # Check the command word of every `|` segment with quotes removed —
    # and, for commands whose own argument is a command, every token of
    # that segment. `&&`/`||`/`;` need no handling: they are rejected
    # above, so `|` is the only separator that can start a new command.
    local -a _cmd_takers=(xargs env nohup timeout watch command sudo)
    local _seg _t _bare _taker
    local -a _segs
    IFS='|' read -r -a _segs <<< "$expanded"
    for _seg in "${_segs[@]}"; do
        # shellcheck disable=SC2206  # word splitting is the point: tokenize the segment
        local -a _toks=(${_seg#!})
        [[ ${#_toks[@]} -eq 0 ]] && continue
        _taker=false
        for _t in "${_cmd_takers[@]}"; do
            [[ "$(strip_quotes "${_toks[0]}")" == "$_t" ]] && _taker=true && break
        done
        for tok in "${_toks[@]}"; do
            _bare=$(strip_quotes "$tok")
            if [[ "$_bare" == ./* && "$_bare" != ./vendor/bin/* ]]; then
                echo "pattern executes './${_bare#./}' in command position; only ./vendor/bin/* is allowed"
                return 1
            fi
            # Only the first word is a command unless the segment's own
            # command takes one; stop after it otherwise.
            $_taker || break
        done
    done

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
