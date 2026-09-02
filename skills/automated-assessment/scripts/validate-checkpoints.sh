#!/usr/bin/env bash
# validate-checkpoints.sh — structural validation of a checkpoints.yaml.
#
# checkpoints-schema.md and learning-derived-checkpoints.md have both told
# authors to run this script; it did not exist. Nothing validated a
# checkpoints.yaml, which is how a `type: command` checkpoint could ship with a
# pattern the runner rejects outright and never execute — a check that reads as
# a gate and is not one.
#
# Beyond the fields the schema documents, this enforces what the runner imposes
# at execution time:
#
#   * the command must live under one of the three keys the runner reads
#     (`pattern:`, `command:`, `target:`) — no narrower, or working checkpoints
#     are reported as broken (they were: all 12 `command:`/`target:` command
#     checkpoints in the estate), and no wider, or unrunnable ones are blessed.
#   * the command must pass the runner's allowlist — sourced from
#     lib/command-allowlist.sh, not reimplemented, so validation and execution
#     cannot disagree. Block-scalar bodies are collected and screened the way
#     the runner screens them: a folded `>` body through the same fold and then
#     the one-liner allowlist, a literal `|` body as a script.
#   * a precondition must be of a type the runner's precondition evaluator
#     actually implements, and its command a single-line scalar it can read —
#     a precondition gates the WHOLE skill, so a defect there is invisible in
#     the report and removes every check the skill owns.
#
# It also warns on the two defect classes no allowlist can see: a `find` with
# no dependency-tree exclusion, and the pipe-into-head exit trap. See
# references/checkpoints-schema.md → "Three defect classes that make a
# checkpoint misreport".
#
# Usage: validate-checkpoints.sh <checkpoints.yaml> [...]
# Exit:  0 = valid, 1 = errors found

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-allowlist.sh
# shellcheck disable=SC1091  # resolved at run time, relative to this script
source "$SCRIPT_DIR/lib/command-allowlist.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
error()   { echo -e "${RED}ERROR:${NC} $1"; ERRORS=$((ERRORS + 1)); }
warning() { echo -e "${YELLOW}WARNING:${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
success() { echo -e "${GREEN}OK:${NC} $1"; }

VALID_TYPES="file_exists file_not_exists contains not_contains regex regex_not json_path yaml_path gh_api command script"
VALID_SEVERITIES="error warning info"
# The runner's precondition evaluator has its own, SHORTER case list than the
# mechanical one (run-checkpoints.sh, `case "$precond_type"`). A precondition
# of any other type never sets precond_ok, so the skill is reported as "not
# applicable" against every project it is ever run on — silently, and for
# reasons no report shows.
VALID_PRECOND_TYPES="file_exists contains regex json_path command"

# --- command screening ------------------------------------------------------
# Screen one command record emitted by the parser below:
#   <id> TAB <key> TAB <kind: single|literal|fold> TAB <body, newlines as \001>
#
# `kind` decides WHICH screen applies, exactly as the runner decides it:
# a folded scalar (`>`) is one logical line and goes through the one-liner
# allowlist; a literal block (`|`) keeps its newlines, reaches the runner as a
# script, and is screened with is_safe_script_text.
screen_command() {
    local rest="$1" cid ckey ckind cval reason text
    IFS=$'\t' read -r cid ckey ckind cval <<<"$rest"
    cval="${cval//$'\001'/$'\n'}"

    if [[ -z "${cval//[$'\n\t ']/}" ]]; then
        error "$cid: '$ckey' is empty — the checkpoint has no command to run"
        return
    fi

    case "$ckind" in
        fold)
            text="$(fold_yaml_block "$cval")"
            # Folding does not always yield ONE line: a blank line inside a
            # folded body is a real line break. The runner routes on the
            # presence of a newline in the final text, so this must too — the
            # one-liner screen's `awk '{print $1}'` on multi-line text produces
            # a nonsense base command and a false error.
            if [[ "$text" == *$'\n'* ]]; then
                if ! reason=$(is_safe_script_text "$text"); then
                    error "$cid: the runner will reject this script body — $reason"
                fi
            elif ! reason=$(is_safe_eval_command "$text"); then
                error "$cid: the runner will reject this pattern — $reason$(class_hint "$text")"
            fi
            ;;
        literal)
            text="$cval"
            if ! reason=$(is_safe_script_text "$text"); then
                error "$cid: the runner will reject this script body — $reason"
            fi
            ;;
        *)
            text="$cval"
            if ! reason=$(is_safe_eval_command "$text"); then
                error "$cid: the runner will reject this pattern — $reason$(class_hint "$text")"
            fi
            ;;
    esac

    warn_defect_classes "$cid" "$text"
}

# Name the authoring defect behind an allowlist rejection when the text shows
# one. "'bash' not in allowed command whitelist" is true and unhelpful; the
# reason the checkpoint was written that way is that its author expected the
# skill's own scripts/ to be reachable, and they never are.
class_hint() {
    local text="$1"
    if [[ "$text" =~ (^|[[:space:]])(bash|sh|source|\.)[[:space:]]+[^[:space:]]*scripts/ ]]; then
        printf ' [defect class 2: a checkpoint runs from the repository under test, where the skill'"'"'s scripts/ does not exist — inline the logic; see checkpoints-schema.md]'
    fi
}

# Heuristics for the two defect classes that produce a WRONG ANSWER rather than
# a rejection — neither is visible to the allowlist, and both shipped in the
# estate. Warnings, not errors: each has legitimate spellings.
warn_defect_classes() {
    local cid="$1" text="$2"
    # `-maxdepth 1` does not descend, so it cannot reach a vendored tree and needs
    # no exclusion — warning on it trains readers to ignore the warning.
    if [[ "$text" =~ (^|[^[:alnum:]_/.])find[[:space:]]+\.[/[:space:]] ]] \
       && [[ ! "$text" =~ (-prune|vendor|node_modules|\.Build|-not[[:space:]]+-path|-maxdepth[[:space:]]+1([[:space:]]|$)) ]]; then
        warning "$cid: 'find .' walks the whole tree with no dependency-tree exclusion [defect class 1] — it will match inside vendor/, node_modules/ and .Build/; the runner's auto-exclude does NOT cover command bodies"
    fi
    # Only the shape where the PIPELINE's own status feeds && / || is defective.
    # `{ cmd || true; } | head` and `x=$(… | head -1)` both take their verdict from
    # somewhere else, so match `| head …` followed by && or || on the same line,
    # and not when the operator is inside a brace group or command substitution
    # that closes before the pipe.
    local _line
    while IFS= read -r _line; do
        [[ "$_line" =~ \|[[:space:]]*head([[:space:]][^|]*)?[[:space:]]*(\&\&|\|\|) ]] || continue
        [[ "$_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && continue   # assignment: status discarded
        [[ "$_line" =~ \}[[:space:]]*\| ]] && continue                        # `{ …; } | head`: guarded upstream
        warning "$cid: 'pipe into head' combined with &&/|| [defect class 3] — head exits 0 on empty input, so the exit status stops depending on whether anything matched"
        break
    done <<< "$text"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: validate-checkpoints.sh <checkpoints.yaml> [...]" >&2
    exit 1
fi

for FILE in "$@"; do
    echo "Validating: $FILE"
    echo "========================================"

    if [[ ! -f "$FILE" ]]; then
        error "no such file: $FILE"
        continue
    fi

    # --- YAML syntax --------------------------------------------------------
    # python3 with PyYAML when available; otherwise skip rather than claim a
    # pass the tool did not earn.
    if python3 -c "import yaml" 2>/dev/null; then
        if python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$FILE" 2>/dev/null; then
            success "YAML parses"
        else
            error "YAML does not parse"
            continue
        fi
    else
        warning "PyYAML unavailable — YAML syntax not checked (field checks still run)"
    fi

    # --- Per-entry field checks --------------------------------------------
    # Line-oriented on purpose: this must see the file the way the runner does
    # — the same three command keys (`pattern`, `command`, `target`), the same
    # block-scalar collection, the same fold. A validator that reads a narrower
    # key set than the runner reports errors on working checkpoints (it did:
    # every `command:`/`target:` command checkpoint in the estate), and a
    # validator that reads a WIDER one blesses checkpoints that never run.
    ids=""
    while IFS= read -r report; do
        case "$report" in
            ERROR:*)   error "${report#ERROR:}" ;;
            WARNING:*) warning "${report#WARNING:}" ;;
            ID:*)      ids="$ids ${report#ID:}" ;;
            CMD:*)     screen_command "${report#CMD:}" ;;
        esac
    done < <(awk '
        # \001 encodes a newline inside a single output record: the bash side
        # decodes it, so a multi-line block body survives a line-oriented pipe.
        BEGIN { SOH = sprintf("%c", 1) }
        function reset_entry(   ) {
            id = ""; type = ""; sev = ""; desc = ""
            v_pat = ""; k_pat = ""; key_pat = ""
            v_target = ""; k_target = ""
            delete seen_fields
        }
        function close_block(   ) {
            inblock = 0
            if (blockkey == "target") { v_target = body; k_target = blockkind }
            else { v_pat = body; k_pat = blockkind; key_pat = blockkey }
            body = ""; bodyind = -1
        }
        function set_field(key, value   ) {
            seen_fields[key] = 1
            if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
            else if (value ~ /^\x27.*\x27$/) { sub(/^\x27/, "", value); sub(/\x27$/, "", value) }
            if (key == "id")            id = value
            else if (key == "type")     type = value
            else if (key == "severity") sev = value
            else if (key == "desc")     desc = value
            else if (key == "pattern" || key == "command") { v_pat = value; k_pat = "single"; key_pat = key }
            else if (key == "target")   { v_target = value; k_target = "single" }
        }
        # Returns 1 when the line was a `key: value` (or block header) line.
        function field_line(line,   key, value, ind) {
            if (match(line, /^[ ]*(- )?[a-z_]+:/) == 0) return 0
            key = substr(line, RSTART, RLENGTH)
            sub(/^[ ]*(- )?/, "", key)
            sub(/:$/, "", key)
            value = substr(line, RSTART + RLENGTH)
            sub(/^[ \t]+/, "", value)
            sub(/[ \t]+$/, "", value)
            if ((key == "pattern" || key == "command" || key == "target") && value ~ /^[|>][-+]?$/) {
                seen_fields[key] = 1
                inblock = 1
                blockkey = key
                blockkind = (substr(value, 1, 1) == ">") ? "fold" : "literal"
                match(line, /^ */); blockind = RLENGTH
                bodyind = -1
                body = ""
                return 1
            }
            set_field(key, value)
            return 1
        }
        function emit_missing(theid, thetype,   need, i, n, parts) {
            if (theid == "" || thetype == "") return
            if (thetype == "file_exists" || thetype == "file_not_exists") need = "target"
            else if (thetype == "contains" || thetype == "not_contains" || thetype == "regex" || thetype == "regex_not" || thetype == "json_path" || thetype == "yaml_path") need = "target pattern"
            else if (thetype == "gh_api") need = "endpoint"
            else need = ""
            n = split(need, parts, " ")
            for (i = 1; i <= n; i++)
                if (!(parts[i] in seen_fields))
                    print "ERROR:" theid ": type " thetype " requires \x27" parts[i] "\x27"
        }
        # The runner reads a command from `pattern:` or `command:` (both land in
        # the same slot) and falls back to `target:`. Mirror that precedence.
        function pick_command(   ) {
            if (v_pat != "") { pick_key = key_pat; pick_kind = k_pat; pick_val = v_pat; return 1 }
            if (v_target != "") { pick_key = "target"; pick_kind = k_target; pick_val = v_target; return 1 }
            pick_key = ""; pick_kind = ""; pick_val = ""
            return 0
        }
        function flush_mech(   ) {
            if (id != "") {
                print "ID:" id
                emit_missing(id, type)
                if (type == "") print "ERROR:" id ": no \x27type\x27"
                else if (index(" " VALID " ", " " type " ") == 0) print "ERROR:" id ": unknown type \x27" type "\x27"
                if (sev != "" && index(" " SEVS " ", " " sev " ") == 0) print "ERROR:" id ": invalid severity \x27" sev "\x27"
                if (desc == "") print "WARNING:" id ": no \x27desc\x27 — assessment output will not say what failed"
                if (type == "command" || type == "script") {
                    if (pick_command())
                        print "CMD:" id "\t" pick_key "\t" pick_kind "\t" pick_val
                    else
                        print "ERROR:" id ": type " type " has no command — give it \x27pattern\x27, \x27command\x27 or \x27target\x27 (the runner reads all three)"
                }
            }
            reset_entry()
        }
        function flush_precond(   pid) {
            if (popen) {
                popen = 0
                pid = "precondition #" pcount
                if (type == "")
                    print "ERROR:" pid ": no \x27type\x27"
                else if (index(" " PTYPES " ", " " type " ") == 0)
                    print "ERROR:" pid ": type \x27" type "\x27 is not evaluated by the runner\x27s precondition parser (accepted: " PTYPES ") — the skill would be skipped against every project"
                else if (type == "command") {
                    if (!pick_command())
                        print "ERROR:" pid ": type command requires \x27pattern\x27 or \x27target\x27"
                    else if (pick_kind != "single")
                        print "ERROR:" pid ": " pick_key " is a block scalar — the precondition parser reads single-line scalars only and would receive the bare indicator, skipping the whole skill"
                    else
                        print "CMD:" pid "\t" pick_key "\tsingle\t" pick_val
                }
                else {
                    if (!("target" in seen_fields))
                        print "ERROR:" pid ": type " type " requires \x27target\x27"
                    else if (type == "file_exists" && (index(v_target, "*") > 0 || index(v_target, "{") > 0))
                        print "ERROR:" pid ": file_exists precondition target \x27" v_target "\x27 uses a glob or brace expansion — the precondition evaluator is a plain [[ -f ]]/[[ -d ]] test, so it matches nothing and skips the skill against every project"
                    if ((type == "contains" || type == "regex" || type == "json_path") && !("pattern" in seen_fields))
                        print "ERROR:" pid ": type " type " requires \x27pattern\x27"
                }
            }
            reset_entry()
        }
        function flush_any(   ) {
            if (section == "mechanical") flush_mech()
            else if (section == "precond") flush_precond()
            else reset_entry()
        }
        # Block bodies are collected BEFORE the comment rule: inside a literal
        # block a `#` line is data, and the runner treats it that way too.
        inblock {
            if ($0 ~ /^[[:space:]]*$/) { body = body SOH; next }
            match($0, /^ */); ind = RLENGTH
            if (ind > blockind) {
                if (bodyind < 0) bodyind = ind
                body = body substr($0, bodyind + 1) SOH
                next
            }
            close_block()
        }
        /^mechanical:/    { flush_any(); section = "mechanical"; next }
        /^llm_reviews:/   { flush_any(); section = "llm";        next }
        /^preconditions:/ { flush_any(); section = "precond";    next }
        /^[a-z_]+:/       { flush_any(); section = "";           next }
        section != "mechanical" && section != "precond" { next }
        /^[[:space:]]*#/ { next }
        {
            if (match($0, /^[ ]*- /)) {
                if (section == "mechanical") flush_mech()
                else { flush_precond(); popen = 1; pcount++ }
            }
            field_line($0)
        }
        END { if (inblock) close_block(); flush_any() }
    ' VALID="$VALID_TYPES" SEVS="$VALID_SEVERITIES" PTYPES="$VALID_PRECOND_TYPES" "$FILE")

    # --- Unique IDs ---------------------------------------------------------
    dupes=$(tr ' ' '\n' <<<"$ids" | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
    dupes="${dupes% }"
    if [[ -n "$dupes" ]]; then
        error "duplicate checkpoint id(s): $dupes"
    fi

    count=$(tr ' ' '\n' <<<"$ids" | grep -vc '^$')
    if [[ "$count" -eq 0 ]]; then
        warning "no mechanical checkpoints found — every rule in this skill is left to an LLM review"
    else
        success "$count mechanical checkpoint(s) validated"
    fi
    echo
done

echo "========================================"
echo "Errors: $ERRORS  Warnings: $WARNINGS"
[[ $ERRORS -eq 0 ]] || exit 1
exit 0
