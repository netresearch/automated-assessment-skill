#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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
# Every command word is classified: the first word of the pattern, the first
# word after each `|`, the command a wrapper runs (found with that wrapper's
# own option grammar, so `xargs -n 1 X`, `xargs -r -I {} X` and
# `timeout 5 X` all reach X) and the first word of each process
# substitution. Each must be on the whitelist or under vendor/bin/. What the
# parser cannot classify is refused: a wrapper or wrapper option outside
# its grammar, `$'...'` quoting outside single quotes, `$"..."` quoting
# and brace expansion outside quotes, an unclosed
# process substitution.
#
# KNOWN-OPEN, deliberately (all verified to execute; none is an accident
# shape, and closing them rejects legitimate checkpoints — a false reject
# silently disables a real check, which is the worse failure):
#
#   * Expansion splices in ARGUMENT position: `find . -exe${x:-c} sh -c
#     id {} +`. In command position a splice is not a whitelisted word and
#     is refused; in an argument it is indistinguishable from `"$f"`.
#     Substituting expansions away and re-scanning also rejects
#     `grep -rq 'rm${IFS}-rf' scripts/` — a checkpoint auditing a project
#     for this very trick — because bash does not expand inside single
#     quotes but a text substitution does not know that.
#   * Traversal spelled through an expansion: `.$1./evil` resolves to
#     `../evil` with no literal `..` anywhere in the text.
#
# Before changing a rule here, run tests/command-allowlist.sh AND score every
# one-line command of the installed checkpoint files with the old and the new
# rule: a verdict that flips on a real checkpoint is a regression until read.
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

# True when the pattern holds a `&` outside quotes that ends a command:
# `cmd & other` runs `other` as a second command, and `|&` pipes into one.
# Redirections (`2>&1`, `<&0`, `&>file`) are not separators. Quote tracking
# as in split_top_level_pipes: a `&` inside a quoted regex or URL is data.
has_top_level_amp() {
    local s="$1" c prev="" next insq=0 indq=0 i bs
    bs=$'\\'
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if (( ! insq )) && [[ "$c" == "$bs" ]]; then
            (( i++ ))
            prev=""
            continue
        fi
        if (( ! indq )) && [[ "$c" == "'" ]]; then
            insq=$(( 1 - insq ))
        elif (( ! insq )) && [[ "$c" == '"' ]]; then
            indq=$(( 1 - indq ))
        elif (( ! insq && ! indq )) && [[ "$c" == '&' ]]; then
            next="${s:i+1:1}"
            if [[ "$prev" != '>' && "$prev" != '<' && "$next" != '>' ]]; then
                return 0
            fi
        fi
        prev="$c"
    done
    return 1
}

strip_quotes() {
    local s="$1" _sq="'" _dq='"'
    s=${s//"$_sq"/}
    s=${s//"$_dq"/}
    printf '%s' "$s"
}

# Split one pipe segment into shell words at whitespace outside quotes,
# keeping the quotes and backslashes in each word; prints each word followed
# by a NUL. A quoted value holding a blank is one word here, as it is for
# bash, so it is read as one option value or one command word.
split_shell_words() {
    local s="$1" c word="" inword=0 insq=0 indq=0 i bs
    bs=$'\\'
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if (( ! insq )) && [[ "$c" == "$bs" ]]; then
            word+="$c${s:i+1:1}"
            inword=1
            i=$(( i + 1 ))
            continue
        fi
        if (( ! indq )) && [[ "$c" == "'" ]]; then
            insq=$(( 1 - insq ))
        elif (( ! insq )) && [[ "$c" == '"' ]]; then
            indq=$(( 1 - indq ))
        elif (( ! insq && ! indq )) && [[ "$c" == [[:space:]] ]]; then
            if (( inword )); then
                printf '%s\0' "$word"
            fi
            word=""
            inword=0
            continue
        fi
        word+="$c"
        inword=1
    done
    if (( inword )); then
        printf '%s\0' "$word"
    fi
    return 0
}

# Constructs outside quotes that let bash build argv bytes or words the text
# checks never see, so no verdict reached on the text holds for what runs:
#   * `$'...'` / `$"..."` quoting: `$'\055r'` is `-r`.
#   * brace expansion: `{rm,-rf}` is two words, `r{m,}` is `rm`.
# A `{...}` without an unquoted comma (`{}`, gh's `{owner}`) and anything in
# single or double quotes (a regex `a{1,3}`, a jq program) stay accepted.
# Returns 0 and prints the reason when one is found.
has_unclassifiable_construct() {
    local s="$1" c next insq=0 indq=0 depth=0 i bs
    bs=$'\\'
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if (( ! insq )) && [[ "$c" == "$bs" ]]; then
            i=$(( i + 1 ))
            continue
        fi
        if (( ! indq )) && [[ "$c" == "'" ]]; then
            insq=$(( 1 - insq ))
            continue
        elif (( ! insq )) && [[ "$c" == '"' ]]; then
            indq=$(( 1 - indq ))
            continue
        fi
        (( insq )) && continue
        next="${s:i+1:1}"
        # `$'` counts inside double quotes too: there it is literal text,
        # except inside `${...}`, where `"${x:-$'\055r'}"` still yields `-r`.
        # `$"` inside double quotes is a `$` before the closing quote, the
        # regex end anchor of `"foo$"`, and stays accepted.
        if [[ "$c" == '$' && ( "$next" == "'" || ( "$next" == '"' && indq -eq 0 ) ) ]]; then
            echo "pattern uses \$'...'/\$\"...\" quoting, which spells bytes the checks cannot read"
            return 0
        fi
        (( indq )) && continue
        if [[ "$c" == '{' ]]; then
            depth=$(( depth + 1 ))
        elif [[ "$c" == '}' ]] && (( depth > 0 )); then
            depth=$(( depth - 1 ))
        elif [[ "$c" == ',' ]] && (( depth > 0 )); then
            echo "pattern uses brace expansion ({a,b}), which builds words the checks cannot read"
            return 0
        fi
    done
    return 1
}

# Process substitution `<(cmd)` / `>(cmd)` runs `cmd` as a command of its own.
# Sets PROCSUB_TEXT to the pattern with each substitution replaced by the word
# PROCSUB and PROCSUB_BODIES to the bodies, so the caller can screen each body
# as a command and the remaining text without them. Quote tracking as in
# split_top_level_pipes: a `<(` inside quotes is data. Returns 1 when a
# substitution is not closed.
PROCSUB_TEXT=""
PROCSUB_BODIES=()
extract_process_substitutions() {
    local s="$1" out="" c insq=0 indq=0 i j depth body bs bq bd
    bs=$'\\'
    PROCSUB_BODIES=()
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if (( ! insq )) && [[ "$c" == "$bs" ]]; then
            out+="$c${s:i+1:1}"
            i=$(( i + 1 ))
            continue
        fi
        if (( ! indq )) && [[ "$c" == "'" ]]; then
            insq=$(( 1 - insq ))
        elif (( ! insq )) && [[ "$c" == '"' ]]; then
            indq=$(( 1 - indq ))
        elif (( ! insq && ! indq )) && [[ ( "$c" == '<' || "$c" == '>' ) && "${s:i+1:1}" == '(' ]]; then
            depth=1 body="" bq=0 bd=0
            for (( j = i + 2; j < ${#s}; j++ )); do
                c="${s:j:1}"
                if (( ! bq )) && [[ "$c" == "$bs" ]]; then
                    body+="$c${s:j+1:1}"
                    j=$(( j + 1 ))
                    continue
                fi
                if (( ! bd )) && [[ "$c" == "'" ]]; then
                    bq=$(( 1 - bq ))
                elif (( ! bq )) && [[ "$c" == '"' ]]; then
                    bd=$(( 1 - bd ))
                elif (( ! bq && ! bd )) && [[ "$c" == '(' ]]; then
                    depth=$(( depth + 1 ))
                elif (( ! bq && ! bd )) && [[ "$c" == ')' ]]; then
                    depth=$(( depth - 1 ))
                    (( depth == 0 )) && break
                fi
                body+="$c"
            done
            (( depth == 0 )) || return 1
            PROCSUB_BODIES+=("$body")
            out+="PROCSUB"
            i=$j
            continue
        fi
        out+="$c"
    done
    PROCSUB_TEXT="$out"
    return 0
}

# Where the command a wrapper runs starts. Reads the global array WRAP_TOKENS
# (quote-stripped words of one pipe segment) from index <start>, the word after
# the wrapper, and prints the index of the wrapped command word, or the array
# length when the wrapper runs nothing named here (`xargs` alone runs echo).
# Each wrapper's options are parsed by its own grammar, so a flag's value
# (`-n 1`, `-I {}`, timeout's duration) is never taken for the command and the
# command behind it is never taken for a value. An option outside the grammar
# returns 1 with a reason: what cannot be classified is not run.
WRAP_TOKENS=()
wrapped_command_index() {
    local w="$1" i="$2" n=${#WRAP_TOKENS[@]} t name k ch
    local vals="" bools="" optional="" lvals="" lbools="" loptional="" positional=0 assign=0 numeric=0
    case "$w" in
        xargs)
            vals=adEILnPs bools=0prtxo optional=eil
            lvals=" arg-file delimiter max-args max-procs max-chars process-slot-var "
            # --eof[=END], --replace[=R], --max-lines[=N]: a value only after `=`.
            loptional=" eof replace max-lines "
            lbools=" null interactive no-run-if-empty verbose exit open-tty " ;;
        env)
            vals=uC bools=i0v assign=1
            lvals=" unset chdir " lbools=" ignore-environment null debug " ;;
        nohup) ;;
        timeout)
            vals=sk bools=v positional=1
            lvals=" signal kill-after " lbools=" preserve-status foreground verbose " ;;
        nice)
            vals=n numeric=1 lvals=" adjustment " ;;
        stdbuf)
            vals=ioe lvals=" input output error " ;;
        command)
            bools=pvV ;;
        *)
            echo "'$w' is not a wrapper this allowlist can parse"
            return 1 ;;
    esac
    while (( i < n )); do
        t="${WRAP_TOKENS[i]}"
        if [[ "$t" == "--" ]]; then
            i=$(( i + 1 ))
            break
        elif [[ "$t" == --* ]]; then
            name="${t#--}"
            if [[ "$name" == *=* ]]; then
                [[ "$lvals$loptional" == *" ${name%%=*} "* ]] || { echo "'$w' option '--${name%%=*}' is not one this allowlist can parse"; return 1; }
                i=$(( i + 1 ))
            elif [[ "$lvals" == *" $name "* ]]; then
                i=$(( i + 2 ))
            elif [[ "$lbools$loptional" == *" $name "* ]]; then
                i=$(( i + 1 ))
            else
                echo "'$w' option '--$name' is not one this allowlist can parse"
                return 1
            fi
        elif [[ "$t" == -?* ]]; then
            if (( numeric )) && [[ "$t" =~ ^-[0-9]+$ ]]; then
                i=$(( i + 1 ))
                continue
            fi
            i=$(( i + 1 ))
            for (( k = 1; k < ${#t}; k++ )); do
                ch="${t:k:1}"
                if [[ -n "$vals" && "$vals" == *"$ch"* ]]; then
                    # The value is the rest of the word, or the next word.
                    (( k + 1 == ${#t} )) && i=$(( i + 1 ))
                    break
                elif [[ -n "$optional" && "$optional" == *"$ch"* ]]; then
                    break
                elif [[ -n "$bools" && "$bools" == *"$ch"* ]]; then
                    continue
                else
                    echo "'$w' option '-$ch' is not one this allowlist can parse"
                    return 1
                fi
            done
        elif (( assign )) && [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            i=$(( i + 1 ))
        else
            break
        fi
    done
    # Positional operands before the command (timeout's DURATION).
    while (( positional > 0 && i < n )); do
        i=$(( i + 1 ))
        positional=$(( positional - 1 ))
    done
    (( assign )) && while (( i < n )) && [[ "${WRAP_TOKENS[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        i=$(( i + 1 ))
    done
    (( i > n )) && i=$n
    printf '%s' "$i"
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
    if [[ "$pattern" =~ (curl[[:space:]].*\|[[:space:]]*(ba)?sh|wget[[:space:]].*\|[[:space:]]*(ba)?sh|eval[[:space:]]|exec(dir)?[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R) ]]; then
        echo "contains dangerous pattern"
        return 1
    fi

    return 0
}

# Validate that a command is safe to eval.
# Uses a whitelist of allowed base commands and rejects dangerous patterns.
# Returns 0 if safe, 1 if rejected (with reason on stdout).
#
# The word the whitelist is applied to: the first field of the one-liner,
# after a leading `!` (POSIX pipeline negation) is stripped so `! grep -q ...`
# yields `grep`. awk's default field splitter handles the leading whitespace
# introduced by the strip. Shared with run-checkpoints.sh, which uses the SAME
# word to tell "the named executable does not exist" (skip) apart from "the
# command ran and failed" (fail) — two definitions of "the command word" would
# let the allowlist and that check disagree about which program a pattern runs.
command_base_word() {
    local stripped="${1#!}"
    awk '{print $1}' <<<"$stripped"
}

# Restrict `gh` to read-only API queries. An assessment runs with the
# operator's gh credentials against the repo under assessment, so a
# checkpoint that reaches for a mutating subcommand (`gh repo edit`, `gh
# release delete`, `gh api -X DELETE ...`) writes to a real repo — the
# highest-blast-radius accident available here. Not containment (see the
# file header): a checkpoint can still shell out via an allowlisted
# interpreter.
#
# Allowed shape: `gh api <endpoint>` with no explicit state-changing method
# (`-X POST|PUT|PATCH|DELETE` / `--method ...`) and no `--input`/`-f`/`-F`
# request-body flags. `gh api` defaults to GET, so a bare `gh api` call is
# safe.
#
# Applied wherever `gh` is a command word: first in the pattern, after a
# `|`, behind a wrapper and its options (`| xargs -n 1 gh ...`), or first in
# a process substitution. A check on the first word alone let
# `grep -q x f | gh repo edit ...` through.
#
# Usage: gh_readonly_check <subcommand word> <text the flag checks read>
# Returns 0 if allowed, 1 if rejected (with reason on stdout).
gh_readonly_check() {
    local _gh_sub="$1" _gh="$2" _sq="'" _dq='"' _bs
    _bs=$'\\'
    _gh_sub=${_gh_sub//"$_bs"/}
    if [[ "$_gh_sub" != "api" ]]; then
        echo "'gh $_gh_sub' is not allowed; only 'gh api' (read-only) is permitted"
        return 1
    fi
    # The flag checks run on a MORE aggressively normalized form than the
    # general checks: a quoted `'-X'` or `"-X"` reaches gh as a bare `-X`
    # (bash removes the quotes), so the quotes come out here too. That is
    # safe in a read-only `gh api` call, whose arguments are an endpoint,
    # flags and a --jq filter — never a quoted filesystem glob that the
    # general `./X` guard protects. $'...'/$"..." quoting can still
    # synthesize `-X` from escapes that no strip reproduces (`$'\055X'`);
    # reject it as a class here, where it has no legitimate use.
    _gh=${_gh//"$_bs"/}
    _gh=${_gh//"$_sq"/}
    _gh=${_gh//"$_dq"/}
    # Brace expansion builds words after this text check (`{-X,DELETE}` runs
    # as `-X DELETE`), so braces and commas count as word breaks here. The
    # gh placeholders `{owner}`, `{repo}` have no comma and stay literal.
    _gh=${_gh//[\{\},]/ }
    if [[ "$_gh" == *'$'* ]]; then
        echo "'gh api' rejected: '\$' (shell/ANSI-C quoting) not allowed in a read-only api call"
        return 1
    fi
    # Reject ANY method flag, in any spelling. gh accepts the value spaced
    # (`-X DELETE`), glued (`-XDELETE`) or with `=`, so match the flag
    # alone rather than the flag+verb — `-XGET` glued would otherwise slip
    # a space-anchored verb check (issue #67 follow-up). `gh api` defaults
    # to GET and no read-only flag begins `-X`/`--method`, so a bare match
    # is safe; the estate uses no method flag.
    if [[ "$_gh" =~ (^|[[:space:]])(-i*X|--method)([[:space:]]|=|[A-Za-z]) ]]; then
        echo "'gh api' rejected: explicit method flag (-X/--method) not allowed; api defaults to GET"
        return 1
    fi
    # Reject ANY request-body flag, in any spelling. These switch gh api to
    # POST. `-f`/`-F` are the short forms of `--raw-field`/`--field`; cover
    # the long aliases and the glued short form (`-fa=b`) the previous
    # space/`=`-anchored check missed. No read-only flag begins `-f`/`-F`.
    if [[ "$_gh" =~ (^|[[:space:]])(--input|--field|--raw-field|-i*f|-i*F) ]]; then
        echo "'gh api' rejected: request-body flags (--input/--field/--raw-field/-f/-F) are not allowed"
        return 1
    fi
    return 0
}

is_safe_eval_command() {
    local pattern="$1"
    # The gh branch below reads the `!`-stripped text as well.
    local stripped="${pattern#!}"
    local cmd_base
    cmd_base=$(command_base_word "$pattern")

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

    local _construct
    if _construct=$(has_unclassifiable_construct "$pattern"); then
        echo "$_construct"
        return 1
    fi

    # Each `<(...)`/`>(...)` body is a command of its own and gets the whole
    # screen; the rest of this function reads the pattern without them, so a
    # `|` inside a body does not split the outer pipeline.
    if ! extract_process_substitutions "$pattern"; then
        echo "pattern has an unclosed process substitution"
        return 1
    fi
    local _outer="$PROCSUB_TEXT" _body _body_reason
    local -a _bodies=("${PROCSUB_BODIES[@]}")
    for _body in "${_bodies[@]}"; do
        if ! _body_reason=$(is_safe_eval_command "$_body"); then
            echo "process substitution: $_body_reason"
            return 1
        fi
    done

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
    if [[ "$normalized" =~ (curl.*\|.*sh|wget.*\|.*sh|eval[[:space:]]|exec(dir)?[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R|\|[[:space:]]*(ba)?sh) ]]; then
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
    # A single `&` ends a command just like `;` (and `|&` pipes into the
    # next one), and nothing below checks what follows it.
    if has_top_level_amp "$pattern"; then
        echo "pattern contains a command-separating '&'"
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
    # Every command word gets the rule the first word gets: a `./` or
    # path-prefixed word only under vendor/bin, and otherwise a word from
    # the whitelist. A wrapper (`xargs`, `env`, `timeout`, ...) is parsed
    # with its own option grammar (wrapped_command_index), so the word it
    # runs is found behind `-n 1`, `-I {}` or a duration, and a wrapper or
    # an option outside that grammar is refused rather than guessed at.
    local _seg _bare _raw _cw _i _next _wrapped _known _acmd
    local -a _segs _toks
    # Split the RAW pattern, not the backslash-stripped one: the quote
    # tracker needs the backslashes to recognise an escaped quote.
    # Newlines first — they are the segment separator below. Process
    # substitutions were screened above and are a placeholder word here.
    local _flat="${_outer//$'\n'/ }"
    mapfile -t _segs < <(split_top_level_pipes "$_flat")
    local _segno=-1
    for _seg in "${_segs[@]}"; do
        _segno=$(( _segno + 1 ))
        # Words as bash splits them: a quoted value with a blank in it is one
        # word, so it cannot pass for an option value and a command.
        mapfile -d '' -t _toks < <(split_shell_words "${_seg#!}")
        WRAP_TOKENS=()
        for _bare in "${_toks[@]}"; do
            _bare=$(strip_quotes "$_bare")
            WRAP_TOKENS+=("${_bare//"$_bs"/}")
        done
        _wrapped=false
        _i=0
        while (( _i < ${#WRAP_TOKENS[@]} )); do
            _bare="${WRAP_TOKENS[_i]}"
            _raw="${_toks[_i]}"
            # A subshell or group opener in front of the word hides it
            # from every test below: `| (gh repo delete ...)` runs gh.
            while [[ "${_bare:0:1}" == "(" || "${_bare:0:1}" == "{" ]]; do _bare=${_bare:1}; done
            while [[ "${_raw:0:1}" == "(" || "${_raw:0:1}" == "{" ]]; do _raw=${_raw:1}; done
            if [[ -z "$_bare" ]]; then
                _i=$(( _i + 1 ))
                continue
            fi
            # Redirections (`>out`, `2>/dev/null`, `3<f`, `&>x`, `<<<s`)
            # and VAR=value assignments may precede the command word; an
            # operator standing alone takes the next word as its target.
            # Bash decides both on the word as written, before quote
            # removal: a quoted `">"x` or `"A=b"/x` is a command word. An
            # assignment counts only before the first command word of the
            # segment; behind a wrapper the word is what the wrapper runs.
            if [[ "$_raw" =~ ^[0-9]*(\<|\>|\&\>) ]]; then
                if [[ "$_raw" =~ ^[0-9]*(\<\<\<|\<\<|\<\>|\<\&|\>\>|\>\&|\>\||\&\>\>|\&\>|\<|\>)$ ]]; then
                    _i=$(( _i + 2 ))
                else
                    _i=$(( _i + 1 ))
                fi
                continue
            fi
            if ! $_wrapped && [[ "$_raw" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                _i=$(( _i + 1 ))
                continue
            fi
            _cw="$_bare"
            if [[ "$_cw" == ./* && "$_cw" != ./vendor/bin/* ]]; then
                (( _reset_f )) || set +f
                echo "pattern executes './${_cw#./}' in command position; only ./vendor/bin/* is allowed"
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
            # A wrapper's wrapped command is the next command word, and that
            # word may be a wrapper again (`xargs env gh ...`).
            case "$_cw" in
                xargs|env|nohup|timeout|nice|stdbuf|command)
                    if ! _next=$(wrapped_command_index "$_cw" $(( _i + 1 ))); then
                        (( _reset_f )) || set +f
                        echo "$_next"
                        return 1
                    fi
                    _i=$_next
                    _wrapped=true
                    continue ;;
            esac
            # The first word of the first segment is checked below, with
            # its own messages; every other command word is checked here.
            if (( _segno > 0 )) || $_wrapped; then
                if [[ "$_cw" != vendor/bin/* && "$_cw" != ./vendor/bin/* ]]; then
                    _known=false
                    for _acmd in "${allowed_cmds[@]}"; do
                        [[ "$_cw" == "$_acmd" ]] && _known=true && break
                    done
                    if ! $_known; then
                        (( _reset_f )) || set +f
                        echo "'$_cw' (command word after a pipe or a wrapper) not in allowed command whitelist"
                        return 1
                    fi
                fi
                # `gh` in any command position gets the same read-only rule
                # as `gh` first in the pattern.
                if [[ "$_cw" == "gh" ]]; then
                    local _ghsub=""
                    (( _i + 1 < ${#WRAP_TOKENS[@]} )) && _ghsub="${WRAP_TOKENS[_i+1]}"
                    if ! gh_readonly_check "$_ghsub" "${_toks[*]:_i}"; then
                        (( _reset_f )) || set +f
                        return 1
                    fi
                fi
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
            # `gh` as the first word: read-only `gh api` only, see
            # gh_readonly_check.
            if [[ "$cmd_base" == "gh" ]]; then
                gh_readonly_check "$(echo "$stripped" | awk '{print $2}')" "$normalized" || return 1
            fi
            return 0
        fi
    done

    echo "'$cmd_base' not in allowed command whitelist"
    return 1
}
