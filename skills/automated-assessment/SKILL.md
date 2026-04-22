---
name: automated-assessment
description: "Use when working with ANY project compliance assessment, quality enhancement, or test suite improvement. MUST be triggered BEFORE manual quality work begins (e.g., to enhance tests, improve coverage, increase mutation score, or strengthen test suite). Also use for: running quality audits against checkpoint-enabled skills, verifying release readiness, mechanical checks, or LLM-assisted code reviews."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash, jq, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "2.7.0"
  repository: https://github.com/netresearch/automated-assessment-skill
allowed-tools: Bash(bash:*) Bash(jq:*) Bash(gh:*) Read Glob Grep Agent
---

# Automated Assessment Skill

Systematic compliance assessment against checkpoint-enabled skills.

## Usage

```
/assess                              # All matching skills
/assess skill-repo typo3-testing     # Specific skills only
/assess --force                      # Ignore preconditions
/assess --mechanical-only            # Scripted checks only
/assess --autofix                    # Fix issues automatically
/assess --review                     # Categorize failures
/assess --autoimprove                # Fix + propose improvements
/assess dependency-compatibility     # Dependency compat checks
/assess --pre-push                   # Pre-push validation gate
/assess --check-coverage             # Verify checkpoint coverage
```

### Options

| Option | Effect |
|--------|--------|
| `<skill-names>` | Run checkpoints for named skills only (also accepts domain names like `dependency-compatibility`) |
| `--force` | Skip precondition checks |
| `--mechanical-only` | Skip LLM reviews |
| `--autofix` | Fix failures via responsible skill, re-verify |
| `--review` | Categorize failures, suggest skill improvements |
| `--autoimprove` | Fix + propose checkpoint changes; add `--create-issues` to file issues |
| `--json` | Raw JSON output |
| `--pre-push` | Run pre-push gate (PHPStan, tests, PHP-CS-Fixer, Rector) |
| `--check-coverage` | Verify adequate checkpoint coverage |

### Steps

1. Discover skills, evaluate preconditions
2. Run mechanical checkpoints
3. Group LLM checkpoints by domain, spawn parallel agents
4. Collect results, generate report

## Assessment-First Rule

**CRITICAL**: Run `/assess` BEFORE manual quality work (enhance tests, improve coverage, strengthen suite, upgrade PHPStan, etc.). Assessment generates a structured gap analysis, preventing wasted iterative discovery.

### Workflow
1. `/assess` with relevant skills
2. Review gap report — this becomes the task list
3. Fix in priority order (errors before warnings; use `--autofix` for automated resolution)
4. Re-run `/assess` to verify

## Checkpoint Types

**Mechanical:** `file_exists`, `file_not_exists`, `contains`, `not_contains`, `regex`, `json_path`, `gh_api`, `command`. **LLM:** `llm_review` (grouped by domain). See `references/checkpoints-schema.md`.

## Domains

`repo-health` `security` `code-quality` `documentation` `git-workflow` `docker` `ddev` `upgrade` `dependency-compatibility` `pre-push`

## Autofix & Review

`--autofix` invokes responsible skill for failures, re-verifies. Statuses: `auto-fixed`, `needs-review`, `unfixable`. `--review`/`--autoimprove` create feedback loops.

## Pre-Push Gate

Only installed tools (`vendor/bin/*`) are checked. Missing tools pass. IDs: PP-01 (PHPStan), PP-02 (PHPUnit), PP-03 (PHP-CS-Fixer), PP-04 (Rector).

## Severity

`error` = blocks release, `warning` = recommendation, `info` = optional.
