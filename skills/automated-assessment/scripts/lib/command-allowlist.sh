#!/usr/bin/env bash
# command-allowlist.sh — the safety filter for checkpoint `type: command`
# patterns, shared by the runner and the authoring-time validator.
#
# Extracted from run-checkpoints.sh so validate-checkpoints.sh applies the
# EXACT rule the runner applies. A second, hand-copied implementation would
# drift, and a checkpoint that passes validation but is rejected at run time
# is worse than no validation: it reads as a check that runs.
#
# Sourced, never executed.


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
    if [[ "$pattern" =~ (curl.*\|.*sh|wget.*\|.*sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R|\|[[:space:]]*(ba)?sh) ]]; then
        echo "contains dangerous pattern"
        return 1
    fi

    # Reject any `..` segment anywhere in the pattern. Path traversal
    # like `vendor/bin/../set` or `./vendor/bin/../../some-script` would
    # otherwise still match the `vendor/bin/*` allow-prefix below while
    # actually resolving outside vendor/bin.
    if [[ "$pattern" =~ \.\. ]]; then
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
    for tok in $pattern; do
        if [[ "$tok" == ./* && "$tok" != ./vendor/bin/* ]]; then
            echo "pattern contains './${tok#./}'; only ./vendor/bin/* is allowed"
            return 1
        fi
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
            # Restrict `gh` to read-only API queries. Checkpoint YAML can
            # come from untrusted skill repos; allowing arbitrary `gh`
            # subcommands would let a checkpoint mutate the repo (`gh repo
            # edit`, `gh release delete`, `gh api -X DELETE ...`, ...).
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
                if [[ "$pattern" =~ (^|[[:space:]])(-X|--method)[[:space:]]+(POST|PUT|PATCH|DELETE) ]]; then
                    echo "'gh api' rejected: state-changing method (-X/--method POST|PUT|PATCH|DELETE)"
                    return 1
                fi
                if [[ "$pattern" =~ (^|[[:space:]])(-X|--method)=(POST|PUT|PATCH|DELETE) ]]; then
                    echo "'gh api' rejected: state-changing method (-X=/--method=POST|PUT|PATCH|DELETE)"
                    return 1
                fi
                if [[ "$pattern" =~ (^|[[:space:]])(--input|-f|-F)([[:space:]]|=) ]]; then
                    echo "'gh api' rejected: request-body flags (--input/-f/-F) are not allowed"
                    return 1
                fi
            fi
            return 0
        fi
    done

    echo "'$cmd_base' not in allowed command whitelist"
    return 1
}
