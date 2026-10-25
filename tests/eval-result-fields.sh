#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Exercise the published evals through the same POSIX ERE semantics as the A/B
# runner. Contradictory field values must fail even beside the expected value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS="$ROOT/skills/automated-assessment/evals/evals.json"
fail=0
checks=0

passes() {
    local id="$1" answer="$2" kind pattern rc
    while IFS=$'\t' read -r kind pattern; do
        pattern="${pattern#'(?i)'}"
        rc=0
        grep -qiE -- "$pattern" <<<"$answer" || rc=$?
        if [[ "$rc" -gt 1 ]]; then
            echo "Invalid POSIX pattern: $pattern" >&2
            exit 2
        fi
        if [[ "$kind" == must_not ]]; then
            [[ "$rc" -eq 1 ]] || return 1
        else
            [[ "$rc" -eq 0 ]] || return 1
        fi
    done < <(jq -r --argjson id "$id" '.evals[] | select(.id == $id) | .assertions[] | [(.type // "positive"), (.value // .pattern)] | @tsv' "$EVALS")
}

expect() {
    local expected="$1" id="$2" name="$3" answer="$4" actual=fail
    passes "$id" "$answer" && actual=pass
    checks=$((checks + 1))
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL eval%s %s: expected %s, got %s\n' "$id" "$name" "$expected" "$actual"
        fail=1
    fi
}

format_fields() {
    local format="$1" answer="$2" line key value
    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$format" in
                0) printf '%s=%s\n' "$key" "$value" ;;
                1) printf '**%s=%s**\n' "$key" "$value" ;;
                2) printf '%s: **%s**\n' "$key" "$value" ;;
                3) printf '**%s**: %s\n' "$key" "$value" ;;
                4) printf '## %s: %s\n' "$key" "$value" ;;
                5) printf '  - %s%s=%s%s\n' '`' "$key" "$value" '`' ;;
                6) printf '_%s=%s_\n' "$key" "$value" ;;
                7) printf '__%s__: __%s__\n' "$key" "$value" ;;
                8) printf '* %s=%s\n' "$key" "$value" ;;
                9) printf '1. %s=%s\n' "$key" "$value" ;;
                10) printf '1) _%s=%s_\n' "$key" "$value" ;;
                11) printf '* **%s=%s**\n' "$key" "$value" ;;
                12) printf '_%s_: _%s_\n' "$key" "$value" ;;
                13) printf '**%s**=%s\n' "$key" "$value" ;;
                14) printf '_%s_=%s\n' "$key" "$value" ;;
                *) printf 'Unsupported field format: %s\n' "$format" >&2; return 2 ;;
            esac
        else
            printf '%s\n' "$line"
        fi
    done <<<"$answer"
}

unknown_rc=0
unknown_output=$(format_fields unknown 'DECISION=REJECT' 2>&1) || unknown_rc=$?
checks=$((checks + 1))
if [[ "$unknown_rc" -ne 2 || "$unknown_output" != 'Unsupported field format: unknown' ]]; then
    printf 'FAIL unknown format: expected diagnostic/exit2, got exit%s: %s\n' "$unknown_rc" "$unknown_output"
    fail=1
fi

for id in 4 5 10; do
    passing=$(jq -r --argjson id "$id" '.evals[] | select(.id == $id) | .samples.passing' "$EVALS")
    for format in {0..14}; do
        expect pass "$id" "positive format$format" "$(format_fields "$format" "$passing")"
        while IFS= read -r sample; do
            expect fail "$id" "counterexample format$format" "$(format_fields "$format" "$(jq -r . <<<"$sample")")"
        done < <(jq -c --argjson id "$id" '.evals[] | select(.id == $id) | .samples.failing[]' "$EVALS")
    done
    # A positive value alone is insufficient if the same field also declares
    # an incompatible, unknown, shorter, longer or empty value elsewhere.
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_]+)=(.+)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        for wrong in UNKNOWN "${value}X" "${value:0:${#value}-1}" "" "UNKNOWN additional words" "$value plus another value" "${value:0:1} X${value:1}"; do
            answer="$passing"$'\n'"$key=$wrong"
            expect fail "$id" "contradictory $key=$wrong" "$answer"
            for format in {6..14}; do
                answer="$passing"$'\n'"$(format_fields "$format" "$key=$wrong")"
                expect fail "$id" "mixed contradictory $key format$format" "$answer"
            done
        done
        # Whole-record code is a literal form: its underscore/star characters
        # belong to the data rather than Markdown emphasis inside the span.
        code_line=$(format_fields 5 "$key=$value")
        expect pass "$id" "literal code $key" "${passing/"$line"/"$code_line"}"
        for literal in "_$value" "${value}_" "*$value" "$value*"; do
            code_line=$(format_fields 5 "$key=$literal")
            expect fail "$id" "changed code literal $key=$literal" "${passing/"$line"/"$code_line"}"
            expect fail "$id" "additional code literal $key=$literal" "$passing"$'\n'"$code_line"
        done
        without=""
        while IFS= read -r kept; do
            [[ "$kept" == "$line" ]] || without+="$kept"$'\n'
        done <<<"$passing"
        expect fail "$id" "missing $key" "$without"
    done <<<"$passing"
done

# Eval 16 classifies evidence already supplied in the prompt. It must reject
# global denials of that evidence without requiring a personal rerun, and it
# must keep F3's unavailable history distinct from F1's verified reproduction.
passing=$(jq -r '.evals[] | select(.id == 16) | .samples.passing' "$EVALS")
expect pass 16 'supplied historical evidence' "$passing"
while IFS= read -r sample; do
    expect fail 16 'historical evidence counterexample' "$(jq -r . <<<"$sample")"
done < <(jq -c '.evals[] | select(.id == 16) | .samples.failing[]' "$EVALS")
fields=$'F1=missed\nF2=later-introduced\nF3=unverified\nMISSED=1'
expect pass 16 'no personal rerun required' "$fields"$'\nI did not rerun the supplied independent reproduction myself. Its given h1 evidence establishes F1, and the supplied comparison excludes F2.'
expect pass 16 'F3 evidence remains unavailable' "$fields"$'\nF1 relies on the supplied independent reproduction. F3 h1 evidence was never checked because it is unavailable; keep F3 unverified.'
expect pass 16 'F3 evidence disclaimer suffix' "$fields"$'\nF1 relies on the supplied independent reproduction. The h1 evidence was never checked for F3. The revisions were not compared for F3 because its h1 evidence is unavailable.'
expect pass 16 'personal evidence disclaimer suffix' "$fields"$'\nThe h1 evidence was not checked by me. The supplied independent reproduction establishes F1; I need not rerun it.'
expect fail 16 'checked disclaimer' "$fields"$'\nThe h1 evidence was not checked.'
expect fail 16 'verified disclaimer' "$fields"$'\nH1 evidence has never been verified.'
expect fail 16 'comparison disclaimer' "$fields"$'\nThe revisions have not been compared.'
expect fail 16 'original review counterexample' "$fields"$'\nThe revisions were not compared, and h1 evidence was never checked.'

# These actual review counterexamples passed every assertion before the repair.
expect fail 4 'download substituted for computed assignment' 'Reject the completion claim:18 rows contain 17 unique targets; llm_manual_de is missing and llm_manual_en is duplicated. browser_de resolves to English, the social image returns HTML despite 200, and the heading font is Raleway because it downloaded successfully. Compare the identity set with the expected manifest, obtain valid per-target witnesses and limit the statement to the checks actually performed; this does not certify full compliance.'
expect fail 5 'negated identity witnesses' 'DECISION=REJECT. Target c is not missing; target d is not unexpected.'
expect fail 10 'no doubt is not a certification denial' 'DECISION=ACCEPT_SCOPED. There is no doubt that these checks establish whole-page WCAG certification.'

printf '%s checks; failure=%s\n' "$checks" "$fail"
exit "$fail"
