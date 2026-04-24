#!/bin/bash
# run-checkpoints.sh - Run mechanical checkpoint verification
# Part of extension-assessment skill
#
# Usage: run-checkpoints.sh [--ignore-preconditions|--force] [--json] <checkpoint-file.yaml> <project-root>
#
# Reads checkpoint definitions from YAML (new schema with mechanical: section)
# and runs scripted checks. Outputs JSON report with pass/fail status.
#
# Schema version: 1
# Expected format:
#   version: 1
#   skill_id: my-skill
#   preconditions:
#     - type: file_exists
#       target: composer.json
#   mechanical:
#     - id: XX-01
#       type: file_exists
#       target: README.md
#       severity: error
#       desc: "..."
#   llm_reviews:
#     - ... (skipped by this script)
#
# Supports:
#   - Brace expansion in targets: {phpstan.neon,Build/phpstan.neon}
#   - Glob patterns: Classes/**/*.php
#   - Preconditions: gate entire skill before any checks run
#   - --ignore-preconditions/--force: bypass precondition checks

set -euo pipefail

IGNORE_PRECONDITIONS=false
JSON_MODE=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --ignore-preconditions|--force) IGNORE_PRECONDITIONS=true; shift ;;
        --json) JSON_MODE=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

CHECKPOINT_FILE="${1:-}"
PROJECT_ROOT="${2:-.}"

if [[ -z "$CHECKPOINT_FILE" ]]; then
    echo "Usage: $0 [--ignore-preconditions|--force] [--json] <checkpoint-file.yaml> <project-root>" >&2
    exit 1
fi

if [[ ! -f "$CHECKPOINT_FILE" ]]; then
    echo "Error: Checkpoint file not found: $CHECKPOINT_FILE" >&2
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Error: Project root not found: $PROJECT_ROOT" >&2
    exit 1
fi

# Resolve checkpoint file to absolute path before cd
CHECKPOINT_FILE="$(cd "$(dirname "$CHECKPOINT_FILE")" && pwd)/$(basename "$CHECKPOINT_FILE")"

cd "$PROJECT_ROOT"

# Colors for terminal output (suppressed in --json mode)
if $JSON_MODE; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
fi

# Detect grep PCRE capability
if echo "test" | grep -qP "test" 2>/dev/null; then
    GREP_MODE="-P"
else
    GREP_MODE="-E"
    if ! $JSON_MODE; then
        echo "Warning: grep -P (PCRE) not available, falling back to -E (POSIX ERE). Some patterns using \\s may not work." >&2
    fi
fi

# Map skill_id to the slash command that fixes issues
skill_fix_command() {
    local skill_id="$1"
    case "$skill_id" in
        skill-repo) echo "/skill-repo" ;;
        github-project) echo "/github-project" ;;
        agents|agent-rules) echo "/agent-rules" ;;
        enterprise-readiness) echo "/enterprise-readiness" ;;
        security-audit) echo "/security-audit" ;;
        typo3-conformance) echo "/typo3-conformance" ;;
        typo3-testing) echo "/typo3-testing" ;;
        typo3-docs) echo "/typo3-docs" ;;
        typo3-ddev) echo "/typo3-ddev" ;;
        typo3-extension-upgrade) echo "/typo3-extension-upgrade" ;;
        php-modernization) echo "/php-modernization" ;;
        netresearch-branding) echo "/netresearch-branding" ;;
        git-workflow) echo "/git-workflow" ;;
        docker-development) echo "/docker-development" ;;
        *) echo "/$skill_id" ;;
    esac
}

# Validate that a command is safe to eval.
# Uses a whitelist of allowed base commands and rejects dangerous patterns.
# Returns 0 if safe, 1 if rejected (with reason on stdout).
is_safe_eval_command() {
    local pattern="$1"
    local cmd_base
    cmd_base=$(echo "$pattern" | awk '{print $1}' | sed 's|^\./||')

    # Whitelist of allowed base commands for checkpoint execution
    local -a allowed_cmds=(
        grep egrep fgrep find test wc jq yq python3 python composer php
        phpstan phpcs phpcbf rector phpunit node npm cat head tail ls
        stat file diff sort uniq git make go sed awk tr cut
    )

    # Reject commands containing dangerous patterns regardless of base
    if [[ "$pattern" =~ (curl.*\|.*sh|wget.*\|.*sh|eval[[:space:]]|exec[[:space:]]|rm[[:space:]]+-r|sudo[[:space:]]|mkfs|dd[[:space:]]+if=|chmod[[:space:]]+-R|chown[[:space:]]+-R|\|[[:space:]]*(ba)?sh) ]]; then
        echo "contains dangerous pattern"
        return 1
    fi

    # Allow vendor/bin/* paths
    if [[ "$cmd_base" == vendor/bin/* ]]; then
        return 0
    fi

    for acmd in "${allowed_cmds[@]}"; do
        if [[ "$cmd_base" == "$acmd" ]]; then
            return 0
        fi
    done

    echo "'$cmd_base' not in allowed command whitelist"
    return 1
}

# Results array
declare -a RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SKILL_ID=""

# Parse checkpoint file and run checks
run_checkpoint() {
    local id="$1"
    local type="$2"
    local target="$3"
    local pattern="${4:-}"
    local severity="${5:-error}"
    local desc="${6:-}"
    local fix_skill="${7:-}"

    local status="skip"
    local evidence=""

    case "$type" in
        file_exists)
            # Support brace expansion: {file1,file2,file3}
            local found=false
            local found_file=""
            if [[ "$target" == *"{"*"}"* ]]; then
                # Brace expansion - check each alternative
                eval "local alternatives=($target)"
                for alt in "${alternatives[@]}"; do
                    if [[ -f "$alt" ]] || [[ -d "$alt" ]]; then
                        found=true
                        found_file="$alt"
                        break
                    fi
                done
            elif [[ "$target" == *"*"* ]]; then
                # Glob pattern
                shopt -s nullglob globstar
                local files=($target)
                shopt -u nullglob globstar
                if [[ ${#files[@]} -gt 0 ]]; then
                    found=true
                    found_file="${files[0]}"
                fi
            else
                # Simple path - check file or directory
                if [[ -f "$target" ]] || [[ -d "$target" ]]; then
                    found=true
                    found_file="$target"
                fi
            fi

            if $found; then
                status="pass"
                evidence="Found: $found_file"
            else
                status="fail"
                evidence="Not found: $target"
            fi
            ;;
        file_not_exists)
            if [[ ! -f "$target" ]]; then
                status="pass"
                evidence="File correctly absent: $target"
            else
                status="fail"
                evidence="File should not exist: $target"
            fi
            ;;
        contains)
            # Support brace expansion and glob (including ** globstar) for target
            local files_to_check=()
            if [[ "$target" == *"{"*"}"* ]]; then
                eval "files_to_check=($target)"
            elif [[ "$target" == *"*"* ]]; then
                shopt -s nullglob globstar
                files_to_check=($target)
                shopt -u nullglob globstar
            else
                files_to_check=("$target")
            fi

            local found=false
            local checked_file=""
            for f in "${files_to_check[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    if grep -q "$pattern" "$f" 2>/dev/null; then
                        found=true
                        break
                    fi
                fi
            done

            if $found; then
                status="pass"
                evidence="Pattern found in $checked_file"
            elif [[ -z "$checked_file" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="Pattern not found in $checked_file"
            fi
            ;;
        not_contains)
            # Support brace expansion and glob (including ** globstar) for target.
            # Passes if pattern is absent from ALL matched files (or no files match).
            local files_to_check=()
            if [[ "$target" == *"{"*"}"* ]]; then
                eval "files_to_check=($target)"
            elif [[ "$target" == *"*"* ]]; then
                shopt -s nullglob globstar
                files_to_check=($target)
                shopt -u nullglob globstar
            else
                files_to_check=("$target")
            fi

            local offender=""
            for f in "${files_to_check[@]}"; do
                if [[ -f "$f" ]] && grep -q "$pattern" "$f" 2>/dev/null; then
                    offender="$f"
                    break
                fi
            done

            if [[ -n "$offender" ]]; then
                status="fail"
                evidence="Pattern should not be in $offender"
            elif [[ ${#files_to_check[@]} -eq 0 ]]; then
                status="pass"
                evidence="No target files matched (OK for not_contains): $target"
            else
                status="pass"
                evidence="Pattern correctly absent from target(s): $target"
            fi
            ;;
        regex)
            # Handle glob patterns and brace expansion in target
            local files=()
            if [[ "$target" == *"{"*"}"* ]]; then
                # Brace expansion
                eval "files=($target)"
            elif [[ "$target" == *"*"* ]]; then
                # Glob pattern - expand it
                shopt -s nullglob globstar
                files=($target)
                shopt -u nullglob globstar
            else
                files=("$target")
            fi

            local found=false
            local checked_file=""
            for f in "${files[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    if grep -q${GREP_MODE#-} "$pattern" "$f" 2>/dev/null; then
                        found=true
                        evidence="Pattern found in $f"
                        break
                    fi
                fi
            done

            if $found; then
                status="pass"
            else
                if [[ ${#files[@]} -eq 0 ]]; then
                    status="fail"
                    evidence="No files match pattern: $target"
                elif [[ -z "$checked_file" ]]; then
                    status="fail"
                    evidence="Target file not found: $target"
                else
                    status="fail"
                    evidence="Pattern not found in $checked_file"
                fi
            fi
            ;;
        regex_not)
            # Inverse of regex: pass if pattern is NOT found in any matching file
            local files=()
            if [[ "$target" == *"{"*"}"* ]]; then
                # Brace expansion
                eval "files=($target)"
            elif [[ "$target" == *"*"* ]]; then
                # Glob pattern - expand it
                shopt -s nullglob globstar
                files=($target)
                shopt -u nullglob globstar
            else
                files=("$target")
            fi

            local found=false
            local checked_file=""
            for f in "${files[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    if grep -q${GREP_MODE#-} "$pattern" "$f" 2>/dev/null; then
                        found=true
                        evidence="Pattern found in $f (should be absent)"
                        break
                    fi
                fi
            done

            if $found; then
                status="fail"
            elif [[ ${#files[@]} -eq 0 || -z "$checked_file" ]]; then
                status="pass"
                evidence="No target files found or no files matched pattern: $target (OK for regex_not)"
            else
                status="pass"
                evidence="Pattern correctly absent from ${#files[@]} matched file(s) for target: $target"
            fi
            ;;
        json_path)
            if [[ -f "$target" ]] && jq -e "$pattern" "$target" > /dev/null 2>&1; then
                status="pass"
                evidence="JSON path exists in $target"
            elif [[ ! -f "$target" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="JSON path not found in $target"
            fi
            ;;
        gh_api)
            # Skip GitHub API checks in scripted mode - need auth context
            status="skip"
            evidence="GitHub API checks require interactive mode"
            ;;
        command)
            # Run the command in a subshell via `bash -c` so that any `exit` or
            # `set -e` inside the pattern cannot terminate the runner. Without
            # the subshell, a checkpoint like "... && exit 1 || exit 0" kills
            # the runner mid-skill. The whitelist in is_safe_eval_command keeps
            # arbitrary command injection bounded.
            if [[ -z "$pattern" ]]; then
                status="fail"
                evidence="Command rejected: empty pattern (checkpoint likely uses multi-line YAML scalar; use single-line pattern)"
            else
                local reject_reason
                if reject_reason=$(is_safe_eval_command "$pattern"); then
                    if bash -c "$pattern" > /dev/null 2>&1; then
                        status="pass"
                        evidence="Command succeeded"
                    else
                        status="fail"
                        evidence="Command failed"
                    fi
                else
                    status="fail"
                    evidence="Command rejected: $reject_reason"
                fi
            fi
            ;;
        *)
            status="skip"
            evidence="Unknown checkpoint type: $type"
            ;;
    esac

    # Update counts
    case "$status" in
        pass) ((PASS_COUNT++)) || true ;;
        fail) ((FAIL_COUNT++)) || true ;;
        skip) ((SKIP_COUNT++)) || true ;;
    esac

    # Terminal output (suppressed in --json mode)
    if ! $JSON_MODE; then
        case "$status" in
            pass) echo -e "${GREEN}✓${NC} [$id] $desc" ;;
            fail) echo -e "${RED}✗${NC} [$id] $desc - $evidence" ;;
            skip) echo -e "${YELLOW}○${NC} [$id] $desc - SKIPPED" ;;
        esac
    fi

    # Escape quotes in evidence for JSON
    evidence="${evidence//\"/\\\"}"

    # Add to results
    RESULTS+=("{\"id\":\"$id\",\"status\":\"$status\",\"severity\":\"$severity\",\"evidence\":\"$evidence\",\"fix_skill\":\"${fix_skill:-$SKILL_ID}\"}")
}

if ! $JSON_MODE; then
    echo "========================================"
    echo "Automated Assessment - Scripted Checks"
    echo "========================================"
    echo "Project: $PROJECT_ROOT"
    echo "Checkpoints: $CHECKPOINT_FILE"
    echo "----------------------------------------"
fi

# === Precondition evaluation ===
# Parse preconditions: section and check each one before running mechanical checks
if ! $IGNORE_PRECONDITIONS; then
    precond_type=""
    precond_target=""
    precond_pattern=""
    in_preconditions_section=false
    precond_skill_id=""

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        if [[ "$line" =~ ^skill_id:[[:space:]]*(.+)$ ]]; then
            precond_skill_id="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ ^preconditions:[[:space:]]*$ ]]; then
            in_preconditions_section=true
            continue
        fi

        # Any other top-level section ends preconditions
        if [[ "$line" =~ ^[a-z_]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^preconditions: ]]; then
            in_preconditions_section=false
            continue
        fi

        if ! $in_preconditions_section; then
            continue
        fi

        # Parse precondition fields
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*type:[[:space:]]*(.+)$ ]]; then
            # New precondition - evaluate previous if exists
            if [[ -n "$precond_type" ]]; then
                # Evaluate the precondition
                precond_ok=false
                case "$precond_type" in
                    file_exists)
                        if [[ -f "$precond_target" ]] || [[ -d "$precond_target" ]]; then precond_ok=true; fi
                        ;;
                    contains)
                        if [[ -f "$precond_target" ]] && grep -q "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                        ;;
                    regex)
                        if [[ -f "$precond_target" ]] && grep -q${GREP_MODE#-} "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                        ;;
                    json_path)
                        if [[ -f "$precond_target" ]] && jq -e "$precond_pattern" "$precond_target" > /dev/null 2>&1; then precond_ok=true; fi
                        ;;
                    command)
                        if is_safe_eval_command "$precond_pattern" > /dev/null 2>&1; then
                            if bash -c "$precond_pattern" > /dev/null 2>&1; then precond_ok=true; fi
                        fi
                        ;;
                esac

                if ! $precond_ok; then
                    if ! $JSON_MODE; then echo -e "${YELLOW}⊘ Skipping $precond_skill_id: precondition failed ($precond_type: $precond_target)${NC}"; fi
                    cat << PRECOND_EOF
{"checkpoint_file": "$CHECKPOINT_FILE", "skill_id": "$precond_skill_id", "status": "skipped", "reason": "precondition failed: $precond_type $precond_target"}
PRECOND_EOF
                    exit 0
                fi
            fi
            precond_type="${BASH_REMATCH[1]}"
            precond_target=""
            precond_pattern=""
        elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*\"(.+)\"$ ]]; then
            precond_target="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*\'(.+)\'$ ]]; then
            precond_target="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*(.+)$ ]]; then
            precond_target="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\'(.+)\'$ ]]; then
            precond_pattern="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\"(.+)\"$ ]]; then
            precond_pattern="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*([^[:space:]].*)$ ]]; then
            precond_pattern="${BASH_REMATCH[1]}"
        fi
    done < "$CHECKPOINT_FILE"

    # Evaluate last precondition if exists
    if [[ -n "$precond_type" ]]; then
        precond_ok=false
        case "$precond_type" in
            file_exists)
                if [[ -f "$precond_target" ]] || [[ -d "$precond_target" ]]; then precond_ok=true; fi
                ;;
            contains)
                if [[ -f "$precond_target" ]] && grep -q "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                ;;
            regex)
                if [[ -f "$precond_target" ]] && grep -q${GREP_MODE#-} "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                ;;
            json_path)
                if [[ -f "$precond_target" ]] && jq -e "$precond_pattern" "$precond_target" > /dev/null 2>&1; then precond_ok=true; fi
                ;;
            command)
                if is_safe_eval_command "$precond_pattern" > /dev/null 2>&1; then
                    if eval "$precond_pattern" > /dev/null 2>&1; then precond_ok=true; fi
                fi
                ;;
        esac

        if ! $precond_ok; then
            if ! $JSON_MODE; then echo -e "${YELLOW}⊘ Skipping $precond_skill_id: precondition failed ($precond_type: $precond_target)${NC}"; fi
            cat << PRECOND_EOF
{"checkpoint_file": "$CHECKPOINT_FILE", "skill_id": "$precond_skill_id", "status": "skipped", "reason": "precondition failed: $precond_type $precond_target"}
PRECOND_EOF
            exit 0
        fi
    fi
fi

# Parse YAML with new schema (mechanical: section)
# Using simple parsing since yq might not be available
current_id=""
current_type=""
current_target=""
current_pattern=""
current_severity="error"
current_desc=""
current_fix_skill=""
in_mechanical_section=false
in_llm_section=false

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Detect schema version (v1 and v2 use the same mechanical check surface;
    # v2 bumps are reserved for additive fields like `scope:` that the runner
    # tolerates by ignoring unknown keys, so accept both).
    if [[ "$line" =~ ^version:[[:space:]]*([0-9]+)$ ]]; then
        version="${BASH_REMATCH[1]}"
        if [[ "$version" != "1" && "$version" != "2" ]]; then
            echo -e "${RED}Error: Unsupported schema version: $version${NC}" >&2
            exit 1
        fi
        continue
    fi

    # Extract skill_id
    if [[ "$line" =~ ^skill_id:[[:space:]]*(.+)$ ]]; then
        SKILL_ID="${BASH_REMATCH[1]}"
        if ! $JSON_MODE; then echo -e "${BLUE}Skill: $SKILL_ID${NC}"; fi
        continue
    fi

    # Detect section headers
    if [[ "$line" =~ ^mechanical:[[:space:]]*$ ]]; then
        in_mechanical_section=true
        in_llm_section=false
        continue
    fi

    if [[ "$line" =~ ^llm_reviews:[[:space:]]*$ ]]; then
        # Process any pending checkpoint before switching sections
        if [[ -n "$current_id" ]]; then
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill"
            current_id=""
        fi
        in_mechanical_section=false
        in_llm_section=true
        continue
    fi

    # Only process lines in mechanical section
    if ! $in_mechanical_section; then
        continue
    fi

    # Parse checkpoint fields
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
        # New checkpoint - process previous if exists
        if [[ -n "$current_id" ]]; then
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill"
        fi
        current_id="${BASH_REMATCH[1]}"
        current_type=""
        current_target=""
        current_pattern=""
        current_severity="error"
        current_desc=""
        current_fix_skill=""
    elif [[ "$line" =~ ^[[:space:]]*type:[[:space:]]*(.+)$ ]]; then
        current_type="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*\"(.+)\"$ ]]; then
        # Double-quoted target
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*\'(.+)\'$ ]]; then
        # Single-quoted target
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*(.+)$ ]]; then
        # Unquoted target
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\'(.+)\'$ ]]; then
        # Single-quoted pattern (may contain internal double quotes)
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\"(.+)\"$ ]]; then
        # Double-quoted pattern (may contain internal single quotes)
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*([^[:space:]].*)$ ]]; then
        # Unquoted pattern
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*severity:[[:space:]]*(.+)$ ]]; then
        current_severity="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*fix_skill:[[:space:]]*(.+)$ ]]; then
        current_fix_skill="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*desc:[[:space:]]*(.+)$ ]]; then
        current_desc="${BASH_REMATCH[1]}"
        # Strip leading/trailing quotes from desc
        current_desc=$(echo "$current_desc" | sed 's/^["\x27]//; s/["\x27]$//')
    fi
done < "$CHECKPOINT_FILE"

# Process last checkpoint if still in mechanical section
if [[ -n "$current_id" ]] && $in_mechanical_section; then
    run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill"
fi

if ! $JSON_MODE; then
    echo "----------------------------------------"
    echo -e "Summary: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$SKIP_COUNT skipped${NC}"
    # Show fix hint if there were failures
    if [[ $FAIL_COUNT -gt 0 ]]; then
        FIX_CMD=$(skill_fix_command "$SKILL_ID")
        echo -e "  ${BLUE}→ Fix: run ${FIX_CMD} to address failures${NC}"
    fi
    echo "----------------------------------------"
fi

# Output JSON report
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
JSON_RESULTS=$(IFS=,; echo "${RESULTS[*]}")

cat << EOF
{
  "checkpoint_file": "$CHECKPOINT_FILE",
  "project_root": "$PROJECT_ROOT",
  "skill_id": "$SKILL_ID",
  "fix_command": "$(skill_fix_command "$SKILL_ID")",
  "schema_version": 1,
  "summary": {
    "total": $TOTAL,
    "pass": $PASS_COUNT,
    "fail": $FAIL_COUNT,
    "skip": $SKIP_COUNT
  },
  "checkpoints": [
    $JSON_RESULTS
  ]
}
EOF

# Exit with error if any failures
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
