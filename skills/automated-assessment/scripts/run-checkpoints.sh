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

# Resolve the github.com owner+repo of the current project from the
# local git origin remote. Sets the globals GH_OWNER and GH_REPO in the
# parent shell — do NOT call via $(...) (that runs in a subshell and the
# globals would not persist). Returns 0 on success, 1 when origin is
# missing, not on github.com, or unparseable.
resolve_github_owner() {
    if [[ -n "${GH_OWNER:-}" && -n "${GH_REPO:-}" ]]; then
        return 0
    fi
    local origin_url stripped owner_repo
    origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
    [[ -z "$origin_url" ]] && return 1
    stripped="${origin_url%/}"
    stripped="${stripped%.git}"
    owner_repo=$(echo "$stripped" | sed -nE 's|^.*github\.com[:/]+([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$|\1/\2|p')
    [[ ! "$owner_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && return 1
    GH_OWNER="${owner_repo%%/*}"
    GH_REPO="${owner_repo##*/}"
    return 0
}

# Check whether the org's .github community-health repo provides a given
# file (e.g. SECURITY.md, CONTRIBUTING.md). Used as a fallback for
# file_exists checkpoints with `org_provides:`. Returns 0 (found), 1 (not
# found / lookup failed). Caches per-(owner,path) in $GH_ORG_PROVIDES_*.
check_org_provides() {
    local rel_path="$1"
    resolve_github_owner || return 1
    [[ -z "${GH_OWNER:-}" ]] && return 1
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        return 1
    fi
    local cache_key="GH_ORG_PROVIDES_${GH_OWNER}_${rel_path//[^A-Za-z0-9]/_}"
    local cached="${!cache_key:-}"
    if [[ "$cached" == "yes" ]]; then return 0; fi
    if [[ "$cached" == "no" ]];  then return 1; fi
    if gh api "repos/${GH_OWNER}/.github/contents/${rel_path}" >/dev/null 2>&1; then
        printf -v "$cache_key" '%s' "yes"
        return 0
    else
        printf -v "$cache_key" '%s' "no"
        return 1
    fi
}

# Tracks fetched-upstream-workflow temp files so the trap at script-end
# can clean them up. Cache by "owner/repo/path@ref" to avoid refetching
# the same upstream workflow across checkpoints.
declare -A FOLLOW_USES_CACHE=()
declare -A FOLLOW_USES_SOURCE=()
declare -a FOLLOW_USES_TEMPFILES=()

cleanup_follow_uses_temps() {
    local f
    for f in "${FOLLOW_USES_TEMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup_follow_uses_temps EXIT

# Given a list of local workflow file paths, scan each for
# `uses: owner/repo/.github/workflows/<file>.yml@<ref>` references,
# fetch the upstream workflow content via `gh api`, write it to a temp
# file, and echo lines `<source-cache-key>\t<tmpfile>` on stdout.
# One hop only — does NOT recurse into the upstream workflow's own
# `uses:` references. Silently skips when gh is missing/unauthenticated.
#
# Stdout format is structured (TAB-separated) because process
# substitution `< <(expand_follow_uses ...)` runs the function in a
# subshell, which means cache assignments to global associative
# arrays would be lost. The caller parses the stdout pairs and
# repopulates FOLLOW_USES_CACHE / FOLLOW_USES_SOURCE / FOLLOW_USES_TEMPFILES
# in the parent shell, so cleanup-on-exit and per-checkpoint dedup work.
expand_follow_uses() {
    local local_file
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        return 0
    fi
    for local_file in "$@"; do
        [[ -f "$local_file" ]] || continue
        # Match  uses: owner/repo/.github/workflows/X.yml@ref
        while IFS= read -r ref_line; do
            local owner_repo path ref cache_key cached_path tmpfile
            if [[ "$ref_line" =~ uses:[[:space:]]+\"?([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/(\.github/workflows/[A-Za-z0-9._/-]+\.ya?ml)@([^[:space:]\"]+) ]]; then
                owner_repo="${BASH_REMATCH[1]}"
                path="${BASH_REMATCH[2]}"
                ref="${BASH_REMATCH[3]}"
                cache_key="${owner_repo}/${path}@${ref}"
                cached_path="${FOLLOW_USES_CACHE[$cache_key]:-}"
                if [[ -n "$cached_path" && -f "$cached_path" ]]; then
                    printf '%s\t%s\n' "$cache_key" "$cached_path"
                    continue
                fi
                tmpfile=$(mktemp --suffix=.yml)
                if gh api "repos/${owner_repo}/contents/${path}?ref=${ref}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null > "$tmpfile" \
                    && [[ -s "$tmpfile" ]]; then
                    printf '%s\t%s\n' "$cache_key" "$tmpfile"
                else
                    rm -f "$tmpfile"
                fi
            fi
        done < <(grep -E '^\s*(- )?\s*uses:' "$local_file" 2>/dev/null || true)
    done
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
SCHEMA_VERSION=1

# Auto-exclude well-known transient/dependency directories from glob expansion
# in *content checks* (regex, regex_not, contains, not_contains). Without this,
# content checks like SA-* `**/*.php` ingest generated DI caches (var/cache/),
# built docs (Documentation-GENERATED-temp/), vendored deps (vendor/,
# node_modules/, .Build/), version control internals (.git/), etc.
#
# `file_exists` glob targets are NOT filtered — some checkpoints intentionally
# count files in vendor/ or .Build/ for sanity checks.
#
# Behaviour:
#   EXCLUDE_PATHS unset      → defaults applied (DEFAULT_EXCLUDE_DIRS)
#   EXCLUDE_PATHS_ADD=...    → newline-separated dirs added on top of defaults
#   EXCLUDE_PATHS=...        → REPLACES the defaults entirely (use this when
#                              a skill needs to scan vendor/ or .Build/ on
#                              purpose, while still excluding only the dirs
#                              listed in EXCLUDE_PATHS)
#
# Matching is by literal path segment (not glob), so a directory name with
# shell metacharacters (* ? [ ]) won't be misinterpreted.
DEFAULT_EXCLUDE_DIRS=(
    .git .svn .hg
    vendor node_modules
    var/cache .Build .build build
    Documentation-GENERATED-temp
    .ddev/.global_commands .ddev/db_snapshots
    .idea .vscode
    coverage .nyc_output
    __pycache__ .pytest_cache .tox
    target dist out
)

# Normalise an exclude entry: strip CR/whitespace.
_normalize_exclude_dir() {
    local dir="$1"
    dir="${dir//$'\r'/}"
    # Trim leading/trailing whitespace
    dir="${dir#"${dir%%[![:space:]]*}"}"
    dir="${dir%"${dir##*[![:space:]]}"}"
    printf '%s' "$dir"
}

if [[ -n "${EXCLUDE_PATHS+x}" ]]; then
    EXCLUDE_DIRS=()
    while IFS= read -r d; do
        d="$(_normalize_exclude_dir "$d")"
        [[ -n "$d" ]] && EXCLUDE_DIRS+=("$d")
    done <<<"$EXCLUDE_PATHS"
else
    EXCLUDE_DIRS=("${DEFAULT_EXCLUDE_DIRS[@]}")
fi
if [[ -n "${EXCLUDE_PATHS_ADD:-}" ]]; then
    while IFS= read -r d; do
        d="$(_normalize_exclude_dir "$d")"
        [[ -n "$d" ]] && EXCLUDE_DIRS+=("$d")
    done <<<"$EXCLUDE_PATHS_ADD"
fi

# Match a path's literal segments against a needle's literal segments
# (sliding window). Avoids bash `case` glob interpretation, so directory
# names containing shell metacharacters (* ? [ ]) are matched literally.
_path_contains_segments() {
    local path="$1"
    local needle="$2"
    local -a path_parts needle_parts
    local i j

    IFS=/ read -r -a path_parts <<<"$path"
    IFS=/ read -r -a needle_parts <<<"$needle"

    [[ ${#needle_parts[@]} -eq 0 ]] && return 1
    [[ ${#needle_parts[@]} -gt ${#path_parts[@]} ]] && return 1

    for ((i = 0; i <= ${#path_parts[@]} - ${#needle_parts[@]}; i++)); do
        for ((j = 0; j < ${#needle_parts[@]}; j++)); do
            [[ "${path_parts[i + j]}" == "${needle_parts[j]}" ]] || break
        done
        [[ $j -eq ${#needle_parts[@]} ]] && return 0
    done
    return 1
}

# is_excluded "path" → returns 0 (true) if path traverses any excluded dir.
is_excluded() {
    local path="$1"
    local dir
    for dir in "${EXCLUDE_DIRS[@]}"; do
        _path_contains_segments "$path" "$dir" && return 0
    done
    return 1
}

# Filter an array of glob-matched paths through is_excluded. Echoes filtered
# paths one per line on stdout.
filter_excluded() {
    local p
    for p in "$@"; do
        is_excluded "$p" || printf '%s\n' "$p"
    done
}

# Parse checkpoint file and run checks
run_checkpoint() {
    local id="$1"
    local type="$2"
    local target="$3"
    local pattern="${4:-}"
    local severity="${5:-error}"
    local desc="${6:-}"
    local fix_skill="${7:-}"
    # 8th arg: org_provides path (file_exists fallback)
    local org_provides="${8:-}"
    # 9th arg: follow_uses flag ("true" enables transitive workflow inspection)
    local follow_uses="${9:-}"

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
            elif [[ -n "$org_provides" ]] && check_org_provides "$org_provides"; then
                status="pass"
                evidence="Satisfied org-wide via ${GH_OWNER:-?}/.github/${org_provides}"
            else
                status="fail"
                evidence="Not found: $target"
                [[ -n "$org_provides" ]] && evidence="$evidence (org_provides: ${GH_OWNER:-?}/.github/${org_provides} also missing)"
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
            # Support brace expansion AND glob (including ** globstar) for
            # target. Brace expansion can produce more glob patterns
            # (e.g. **/*.{js,ts} → **/*.js, **/*.ts), which then need glob
            # expansion themselves. Detect whether target uses a glob/brace
            # expansion so we can apply the "no matches → skip" semantic only
            # to globs (a literal path that doesn't exist is still a real
            # failure). Glob matches are filtered through the auto-exclude
            # list so generated caches/vendored deps don't show up as findings.
            local has_glob=false
            local files_to_check=() patterns=() raw_files=()
            if [[ "$target" == *"{"*"}"* || "$target" == *"*"* ]]; then
                has_glob=true
                if [[ "$target" == *"{"*"}"* ]]; then
                    eval "patterns=($target)"
                else
                    patterns=("$target")
                fi
                shopt -s nullglob globstar
                for p in "${patterns[@]}"; do
                    if [[ "$p" == *"*"* ]]; then
                        for ff in $p; do raw_files+=("$ff"); done
                    else
                        raw_files+=("$p")
                    fi
                done
                shopt -u nullglob globstar
                if [[ ${#raw_files[@]} -gt 0 ]]; then
                    while IFS= read -r f; do
                        files_to_check+=("$f")
                    done < <(filter_excluded "${raw_files[@]}")
                fi
            else
                files_to_check=("$target")
            fi

            # follow_uses: also search any reusable workflow referenced
            # by `uses:` in the target files (one hop, fetched via gh api).
            if [[ "$follow_uses" == "true" ]]; then
                local _src _tmp
                while IFS=$'\t' read -r _src _tmp; do
                    [[ -z "$_tmp" ]] && continue
                    files_to_check+=("$_tmp")
                    FOLLOW_USES_CACHE[$_src]="$_tmp"
                    FOLLOW_USES_SOURCE[$_tmp]="$_src"
                    FOLLOW_USES_TEMPFILES+=("$_tmp")
                done < <(expand_follow_uses "${files_to_check[@]}")
            fi

            local found=false
            local checked_file=""
            for f in "${files_to_check[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    # `contains` is documented as literal string search (per
                    # references/checkpoints-schema.md); use -F so regex
                    # metacharacters in the pattern (e.g. `..` in `../`)
                    # don't produce false positives by matching arbitrary
                    # characters. Use `regex` for regex matching.
                    if grep -qF -- "$pattern" "$f" 2>/dev/null; then
                        found=true
                        break
                    fi
                fi
            done

            if $found; then
                status="pass"
                local _src="${FOLLOW_USES_SOURCE[$checked_file]:-}"
                if [[ -n "$_src" ]]; then
                    evidence="Pattern found via reusable workflow $_src"
                else
                    evidence="Pattern found in $checked_file"
                fi
            elif $has_glob && [[ -z "$checked_file" ]]; then
                # Glob target with zero matching files → checkpoint is N/A
                # (e.g. SA-PY-* targeting **/*.py on a repo with no Python).
                status="skip"
                evidence="No files match glob: $target (checkpoint not applicable)"
            elif [[ -z "$checked_file" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="Pattern not found in $checked_file"
            fi
            ;;
        not_contains)
            # Support brace expansion + glob (including ** globstar) for target.
            # Passes if pattern is absent from ALL matched files (or no files match).
            # Glob matches are filtered through the auto-exclude list.
            local files_to_check=() patterns=() raw_files=()
            if [[ "$target" == *"{"*"}"* || "$target" == *"*"* ]]; then
                if [[ "$target" == *"{"*"}"* ]]; then
                    eval "patterns=($target)"
                else
                    patterns=("$target")
                fi
                shopt -s nullglob globstar
                for p in "${patterns[@]}"; do
                    if [[ "$p" == *"*"* ]]; then
                        for ff in $p; do raw_files+=("$ff"); done
                    else
                        raw_files+=("$p")
                    fi
                done
                shopt -u nullglob globstar
                if [[ ${#raw_files[@]} -gt 0 ]]; then
                    while IFS= read -r f; do
                        files_to_check+=("$f")
                    done < <(filter_excluded "${raw_files[@]}")
                fi
            else
                files_to_check=("$target")
            fi

            local offender=""
            for f in "${files_to_check[@]}"; do
                # `not_contains` is documented as literal string search; use -F
                # so regex metacharacters in the pattern don't produce false
                # positives. Use `regex_not` for regex matching.
                if [[ -f "$f" ]] && grep -qF -- "$pattern" "$f" 2>/dev/null; then
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
            # Handle glob patterns and brace expansion in target.
            # Track whether the target uses a glob/brace pattern so that
            # zero matches against a glob is treated as "checkpoint not
            # applicable" (skip) rather than a hard failure — e.g.
            # SA-PY-* targeting **/*.py on a TYPO3 PHP-only repo.
            # Brace expansion can produce more glob patterns
            # (e.g. **/*.{js,ts} → **/*.js, **/*.ts), so we expand globs
            # AFTER brace expansion. Glob matches are filtered through the
            # auto-exclude list.
            local has_glob=false
            local files=() patterns=() raw_files=()
            if [[ "$target" == *"{"*"}"* || "$target" == *"*"* ]]; then
                has_glob=true
                if [[ "$target" == *"{"*"}"* ]]; then
                    eval "patterns=($target)"
                else
                    patterns=("$target")
                fi
                shopt -s nullglob globstar
                for p in "${patterns[@]}"; do
                    if [[ "$p" == *"*"* ]]; then
                        for ff in $p; do raw_files+=("$ff"); done
                    else
                        raw_files+=("$p")
                    fi
                done
                shopt -u nullglob globstar
                if [[ ${#raw_files[@]} -gt 0 ]]; then
                    while IFS= read -r f; do
                        files+=("$f")
                    done < <(filter_excluded "${raw_files[@]}")
                fi
            else
                files=("$target")
            fi

            # follow_uses: also search any reusable workflow referenced
            # by `uses:` in the target files (one hop, fetched via gh api).
            if [[ "$follow_uses" == "true" ]]; then
                local _src _tmp
                while IFS=$'\t' read -r _src _tmp; do
                    [[ -z "$_tmp" ]] && continue
                    files+=("$_tmp")
                    FOLLOW_USES_CACHE[$_src]="$_tmp"
                    FOLLOW_USES_SOURCE[$_tmp]="$_src"
                    FOLLOW_USES_TEMPFILES+=("$_tmp")
                done < <(expand_follow_uses "${files[@]}")
            fi

            local found=false
            local checked_file=""
            for f in "${files[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    if grep -q${GREP_MODE#-} -- "$pattern" "$f" 2>/dev/null; then
                        found=true
                        local _src="${FOLLOW_USES_SOURCE[$f]:-}"
                        if [[ -n "$_src" ]]; then
                            evidence="Pattern found via reusable workflow $_src"
                        else
                            evidence="Pattern found in $f"
                        fi
                        break
                    fi
                fi
            done

            if $found; then
                status="pass"
            elif $has_glob && [[ ${#files[@]} -eq 0 ]]; then
                status="skip"
                evidence="No files match glob: $target (checkpoint not applicable)"
            elif [[ -z "$checked_file" ]]; then
                status="fail"
                evidence="Target file not found: $target"
            else
                status="fail"
                evidence="Pattern not found in $checked_file"
            fi
            ;;
        regex_not)
            # Inverse of regex: pass if pattern is NOT found in any matching file.
            # Handles brace expansion + glob (incl. globstar) consistently with
            # the other handlers. Glob matches filtered via auto-exclude list.
            local files=() patterns=() raw_files=()
            if [[ "$target" == *"{"*"}"* || "$target" == *"*"* ]]; then
                if [[ "$target" == *"{"*"}"* ]]; then
                    eval "patterns=($target)"
                else
                    patterns=("$target")
                fi
                shopt -s nullglob globstar
                for p in "${patterns[@]}"; do
                    if [[ "$p" == *"*"* ]]; then
                        for ff in $p; do raw_files+=("$ff"); done
                    else
                        raw_files+=("$p")
                    fi
                done
                shopt -u nullglob globstar
                if [[ ${#raw_files[@]} -gt 0 ]]; then
                    while IFS= read -r f; do
                        files+=("$f")
                    done < <(filter_excluded "${raw_files[@]}")
                fi
            else
                files=("$target")
            fi

            local found=false
            local checked_file=""
            for f in "${files[@]}"; do
                if [[ -f "$f" ]]; then
                    checked_file="$f"
                    if grep -q${GREP_MODE#-} -- "$pattern" "$f" 2>/dev/null; then
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
            # Run when gh CLI is available and authenticated. Resolves
            # {owner}/{repo}/{default_branch} from the local origin remote
            # and tests the response with `jq -e <json_path>`.
            #
            # Field mapping: `endpoint:` is parsed into $target,
            # `json_path:` into $pattern (set above by the field parser).
            if ! command -v gh >/dev/null 2>&1; then
                status="skip"
                evidence="gh CLI not available"
            elif ! gh auth status >/dev/null 2>&1; then
                status="skip"
                evidence="gh CLI not authenticated (run: gh auth login)"
            elif [[ -z "$target" || -z "$pattern" ]]; then
                status="skip"
                evidence="gh_api checkpoint missing endpoint or json_path"
            else
                local resolved_endpoint api_response
                if ! resolve_github_owner; then
                    status="skip"
                    evidence="Cannot resolve github.com owner/repo from local origin remote"
                else
                    # Resolve and cache {default_branch} once per runner invocation
                    if [[ -z "${GH_DEFAULT_BRANCH:-}" ]]; then
                        GH_DEFAULT_BRANCH=$(gh repo view "${GH_OWNER}/${GH_REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
                    fi
                    resolved_endpoint="${target//\{owner\}/$GH_OWNER}"
                    resolved_endpoint="${resolved_endpoint//\{repo\}/$GH_REPO}"
                    resolved_endpoint="${resolved_endpoint//\{default_branch\}/$GH_DEFAULT_BRANCH}"
                    local api_stderr
                    api_stderr=$(mktemp)
                    if api_response=$(gh api "$resolved_endpoint" 2>"$api_stderr"); then
                        if echo "$api_response" | jq -e "$pattern" >/dev/null 2>&1; then
                            status="pass"
                            evidence="GitHub API $resolved_endpoint: $pattern truthy"
                        else
                            status="fail"
                            evidence="GitHub API $resolved_endpoint: $pattern is null/false/missing"
                        fi
                    else
                        # Reflect the gh stderr so the user can distinguish 404 vs auth/network failures
                        local err_msg
                        err_msg=$(tr -d '\n' <"$api_stderr" | head -c 200)
                        status="fail"
                        evidence="GitHub API call failed: $resolved_endpoint — ${err_msg:-no error message}"
                    fi
                    rm -f "$api_stderr"
                fi
            fi
            ;;
        command)
            # Run the command in a child bash via here-string so that any
            # `exit` or `set -e` inside the pattern cannot terminate the
            # runner. We use `bash <<<"$pattern"` (rather than `bash -c
            # "$pattern"`) so that `$variables` inside the pattern are
            # resolved by the *child* bash, not pre-expanded against the
            # runner's empty scope. The whitelist in is_safe_eval_command
            # keeps arbitrary command injection bounded.
            #
            # Field name resolution: prefer `pattern:`, then fall back to
            # `command:` (already aliased into $pattern) and `target:`. Some
            # skills (notably security-audit) put the command in `target:`,
            # which is technically a schema deviation but common enough to
            # accept transparently.
            local cmd_text="$pattern"
            if [[ -z "$cmd_text" && -n "$target" ]]; then
                cmd_text="$target"
            fi
            if [[ -z "$cmd_text" ]]; then
                status="fail"
                evidence="Command rejected: empty pattern (checkpoint likely uses multi-line YAML scalar; use single-line pattern, or put the command in pattern:/target:)"
            else
                local reject_reason
                if reject_reason=$(is_safe_eval_command "$cmd_text"); then
                    if bash <<<"$cmd_text" > /dev/null 2>&1; then
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
    precond_desc=""
    precond_cmd=""
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
                        if [[ -f "$precond_target" ]] && grep -qF -- "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                        ;;
                    regex)
                        if [[ -f "$precond_target" ]] && grep -q${GREP_MODE#-} -- "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                        ;;
                    json_path)
                        if [[ -f "$precond_target" ]] && jq -e "$precond_pattern" "$precond_target" > /dev/null 2>&1; then precond_ok=true; fi
                        ;;
                    command)
                        precond_cmd="${precond_pattern:-$precond_target}"
                        if [[ -n "$precond_cmd" ]] && is_safe_eval_command "$precond_cmd" > /dev/null 2>&1; then
                            if bash -c "$precond_cmd" > /dev/null 2>&1; then precond_ok=true; fi
                        fi
                        ;;
                esac

                if ! $precond_ok; then
                    precond_detail="${precond_cmd:-$precond_target}"
                    if [[ -n "$precond_desc" ]]; then
                        precond_detail="$precond_detail — $precond_desc"
                    fi
                    if ! $JSON_MODE; then echo -e "${YELLOW}⊘ Skipping $precond_skill_id: precondition failed ($precond_type: $precond_detail)${NC}"; fi
                    cat << PRECOND_EOF
{"checkpoint_file": "$CHECKPOINT_FILE", "skill_id": "$precond_skill_id", "status": "skipped", "reason": "precondition failed: $precond_type $precond_detail"}
PRECOND_EOF
                    exit 0
                fi
            fi
            precond_type="${BASH_REMATCH[1]}"
            precond_target=""
            precond_pattern=""
            precond_desc=""
            precond_cmd=""
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
        elif [[ "$line" =~ ^[[:space:]]*desc:[[:space:]]*\"(.+)\"$ ]]; then
            precond_desc="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*desc:[[:space:]]*\'(.+)\'$ ]]; then
            precond_desc="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*desc:[[:space:]]*(.+)$ ]]; then
            precond_desc="${BASH_REMATCH[1]}"
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
                if [[ -f "$precond_target" ]] && grep -qF -- "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                ;;
            regex)
                if [[ -f "$precond_target" ]] && grep -q${GREP_MODE#-} -- "$precond_pattern" "$precond_target" 2>/dev/null; then precond_ok=true; fi
                ;;
            json_path)
                if [[ -f "$precond_target" ]] && jq -e "$precond_pattern" "$precond_target" > /dev/null 2>&1; then precond_ok=true; fi
                ;;
            command)
                precond_cmd="${precond_pattern:-$precond_target}"
                if [[ -n "$precond_cmd" ]] && is_safe_eval_command "$precond_cmd" > /dev/null 2>&1; then
                    if bash <<<"$precond_cmd" > /dev/null 2>&1; then precond_ok=true; fi
                fi
                ;;
        esac

        if ! $precond_ok; then
            precond_detail="${precond_cmd:-$precond_target}"
            if [[ -n "$precond_desc" ]]; then
                precond_detail="$precond_detail — $precond_desc"
            fi
            if ! $JSON_MODE; then echo -e "${YELLOW}⊘ Skipping $precond_skill_id: precondition failed ($precond_type: $precond_detail)${NC}"; fi
            cat << PRECOND_EOF
{"checkpoint_file": "$CHECKPOINT_FILE", "skill_id": "$precond_skill_id", "status": "skipped", "reason": "precondition failed: $precond_type $precond_detail"}
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
current_org_provides=""
current_follow_uses=""
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
        SCHEMA_VERSION="${BASH_REMATCH[1]}"
        if [[ "$SCHEMA_VERSION" != "1" && "$SCHEMA_VERSION" != "2" ]]; then
            echo -e "${RED}Error: Unsupported schema version: $SCHEMA_VERSION${NC}" >&2
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
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill" "$current_org_provides" "$current_follow_uses"
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
        # Capture the new id BEFORE calling run_checkpoint — that function
        # uses `[[ =~ ]]` internally (e.g. in the gh_api branch), which
        # clobbers BASH_REMATCH in the parent shell.
        _new_id="${BASH_REMATCH[1]}"
        # New checkpoint - process previous if exists
        if [[ -n "$current_id" ]]; then
            run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill" "$current_org_provides" "$current_follow_uses"
        fi
        current_id="$_new_id"
        current_type=""
        current_target=""
        current_pattern=""
        current_severity="error"
        current_desc=""
        current_fix_skill=""
        current_org_provides=""
        current_follow_uses=""
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
    elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*\'(.+)\'$ ]]; then
        # `command:` is an accepted alias for `pattern:` on type=command
        # checkpoints (in active use by php-modernization, typo3-testing,
        # typo3-conformance, enterprise-readiness, agent-harness, github-release).
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*\"(.+)\"$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*([^[:space:]].*)$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*endpoint:[[:space:]]*\"(.+)\"$ ]]; then
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*endpoint:[[:space:]]*\'(.+)\'$ ]]; then
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*endpoint:[[:space:]]*(.+)$ ]]; then
        current_target="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*json_path:[[:space:]]*\"(.+)\"$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*json_path:[[:space:]]*\'(.+)\'$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*json_path:[[:space:]]*(.+)$ ]]; then
        current_pattern="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*org_provides:[[:space:]]*\"(.+)\"$ ]]; then
        current_org_provides="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*org_provides:[[:space:]]*\'(.+)\'$ ]]; then
        current_org_provides="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*org_provides:[[:space:]]*(.+)$ ]]; then
        current_org_provides="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*follow_uses:[[:space:]]*(true|false)$ ]]; then
        current_follow_uses="${BASH_REMATCH[1]}"
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
    run_checkpoint "$current_id" "$current_type" "$current_target" "$current_pattern" "$current_severity" "$current_desc" "$current_fix_skill" "$current_org_provides" "$current_follow_uses"
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
  "schema_version": $SCHEMA_VERSION,
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
