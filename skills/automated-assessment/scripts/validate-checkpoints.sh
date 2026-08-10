#!/usr/bin/env bash
# validate-checkpoints.sh — structural validation of a checkpoints.yaml.
#
# checkpoints-schema.md and learning-derived-checkpoints.md have both told
# authors to run this script; it did not exist. Nothing validated a
# checkpoints.yaml, which is how a `type: command` checkpoint could ship with a
# pattern the runner rejects outright and never execute — a check that reads as
# a gate and is not one.
#
# Beyond the fields the schema documents, this enforces the two constraints the
# runner imposes at execution time and the schema never wrote down:
#
#   * `pattern:` must be a single-line scalar. The runner parses YAML line by
#     line; `pattern: |-` reaches it as the literal `|-`, which is not a
#     command.
#   * the command must pass the runner's allowlist — sourced from
#     lib/command-allowlist.sh, not reimplemented, so validation and execution
#     cannot disagree.
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

VALID_TYPES="file_exists file_not_exists contains not_contains regex regex_not json_path yaml_path gh_api command"
VALID_SEVERITIES="error warning info"

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
    # Line-oriented on purpose: this must see the file the way the runner does,
    # including a multi-line scalar the runner cannot handle.
    ids=""
    while IFS= read -r report; do
        case "$report" in
            ERROR:*)   error "${report#ERROR:}" ;;
            WARNING:*) warning "${report#WARNING:}" ;;
            ID:*)      ids="$ids ${report#ID:}" ;;
            CMD:*)
                # CMD:<id>\t<pattern>
                rest="${report#CMD:}"
                cid="${rest%%	*}"
                cpat="${rest#*	}"
                if [[ -z "$cpat" || "$cpat" == "|" || "$cpat" == "|-" || "$cpat" == ">" || "$cpat" == ">-" ]]; then
                    error "$cid: 'pattern' is a multi-line YAML scalar; the runner reads it line by line and receives '${cpat:-<empty>}' — use a single-line pattern"
                elif ! reason=$(is_safe_eval_command "$cpat"); then
                    error "$cid: the runner will reject this pattern — $reason"
                fi
                ;;
        esac
    done < <(awk '
        function emit_missing(id, type,   need, i, n, parts) {
            if (id == "" || type == "") return
            if (type == "file_exists" || type == "file_not_exists") need = "target"
            else if (type == "contains" || type == "not_contains" || type == "regex" || type == "regex_not" || type == "json_path" || type == "yaml_path") need = "target pattern"
            else if (type == "command") need = "pattern"
            else if (type == "gh_api") need = "endpoint"
            else need = ""
            n = split(need, parts, " ")
            for (i = 1; i <= n; i++)
                if (!(parts[i] in seen_fields))
                    print "ERROR:" id ": type " type " requires \x27" parts[i] "\x27"
        }
        function flush(   ) {
            if (id != "") {
                print "ID:" id
                emit_missing(id, type)
                if (type == "") print "ERROR:" id ": no \x27type\x27"
                else if (index(" " VALID " ", " " type " ") == 0) print "ERROR:" id ": unknown type \x27" type "\x27"
                if (sev != "" && index(" " SEVS " ", " " sev " ") == 0) print "ERROR:" id ": invalid severity \x27" sev "\x27"
                if (desc == "") print "WARNING:" id ": no \x27desc\x27 — assessment output will not say what failed"
                if (type == "command") print "CMD:" id "\t" pat
            }
            id = ""; type = ""; sev = ""; desc = ""; pat = ""
            delete seen_fields
        }
        /^mechanical:/  { flush(); section = "mechanical"; next }
        /^llm_reviews:/ { flush(); section = "llm";        next }
        /^[a-z_]+:/     { flush(); section = "";           next }
        section != "mechanical" { next }
        /^[[:space:]]*#/ { next }
        /^  - id:/ { flush(); id = $3; next }
        /^    [a-z_]+:/ {
            key = $1; sub(/:$/, "", key)
            seen_fields[key] = 1
            value = $0
            sub(/^    [a-z_]+:[[:space:]]*/, "", value)
            # strip one layer of matching quotes
            if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
            else if (value ~ /^\x27.*\x27$/) { sub(/^\x27/, "", value); sub(/\x27$/, "", value) }
            if (key == "type")     type = value
            if (key == "severity") sev  = value
            if (key == "desc")     desc = value
            if (key == "pattern")  pat  = value
        }
        END { flush() }
    ' VALID="$VALID_TYPES" SEVS="$VALID_SEVERITIES" "$FILE")

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
