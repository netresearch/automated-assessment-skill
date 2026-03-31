---
name: automated-assessment
description: "Use when working with ANY project compliance assessment, quality enhancement, or test suite improvement. MUST be triggered BEFORE manual quality work begins (enhance tests, improve coverage, increase mutation score, enterprise grade, A+ testing, strengthen test suite). Also use for: running quality audits against checkpoint-enabled skills, verifying release readiness, mechanical checks, or LLM-assisted code reviews."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash, jq, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "2.6.0"
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

## When to Trigger This Skill

**CRITICAL**: This skill must be invoked BEFORE starting manual quality enhancement work. When a user asks to:
- "enhance the test suite" / "improve tests" / "strengthen tests"
- "increase coverage" / "improve mutation score"
- "enterprise grade" / "A+ testing" / "production ready"
- "add architecture tests" / "improve static analysis"
- "upgrade PHPStan level" / "fix all findings"

**Always run assessment first** to generate a structured gap analysis. This prevents wasted effort discovering issues iteratively that checkpoints would have caught automatically.

### Assessment-First Workflow
1. Run `/assess` against the project with relevant skills
2. Review the gap report — this becomes the task list
3. Fix issues in priority order (errors before warnings)
4. Re-run `/assess` to verify all checkpoints pass

## Checkpoint Types

**Mechanical:** `file_exists`, `file_not_exists`, `contains`, `not_contains`, `regex`, `json_path`, `gh_api`, `command`. **LLM:** `llm_review` (grouped by domain). See `references/checkpoints-schema.md`.

## Domain Groups

| Domain | Focus |
|--------|-------|
| `repo-health` | README, badges, branding, AGENTS.md |
| `security` | SLSA, OpenSSF, SBOM |
| `code-quality` | PHPStan, tests, PHP 8.x |
| `documentation` | RST, docs.typo3.org |
| `git-workflow` | Branching, conventional commits |
| `docker` | Dockerfile, compose |
| `ddev` | DDEV config, services |
| `upgrade` | TYPO3 version upgrades |
| `dependency-compatibility` | Multi-version API compat, mocks, PHPStan ignores |
| `pre-push` | Local CI gate (PHPStan, tests, PHP-CS-Fixer, Rector) |

## Autofix & Review

`--autofix` runs checks, invokes responsible skill for failures, re-verifies. Statuses: `auto-fixed`, `needs-review`, `unfixable`.

`--review`/`--autoimprove` create feedback loops. Categories: `fixable`, `skill-gap`, `checkpoint-issue`.

## Dependency Compatibility

Triggered when `composer.json` spans multiple major versions (e.g., `^2.0 || ^3.0`). Verifies all versions install, PHPStan/tests pass per version, and API calls are compatible. See `references/dependency-compatibility.md`.

## Pre-Push Validation Gate

Only installed tools (`vendor/bin/*`) are checked. Missing tools pass (not failed).

| Tool | ID | Severity |
|------|----|----------|
| PHPStan | PP-01 | error |
| PHPUnit | PP-02 | error |
| PHP-CS-Fixer | PP-03 | warning |
| Rector | PP-04 | warning |

## Checkpoint Coverage

`--check-coverage` verifies skills cover: API compatibility, test mock validity, PHPStan ignore validity, assertion specificity. See `references/checkpoint-coverage-requirements.md`.

## Severity

`error` = blocks release, `warning` = recommendation, `info` = optional.
