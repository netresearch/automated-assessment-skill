---
name: automated-assessment
description: "Use when working with ANY project compliance assessment — running quality audits against checkpoint-enabled skills, verifying release readiness, mechanical checks, or LLM-assisted code reviews."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash, jq, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "2.6.0"
  repository: https://github.com/netresearch/automated-assessment-skill
allowed-tools: Bash(bash:*) Bash(jq:*) Bash(gh:*) Read Glob Grep Agent
---

# Automated Assessment Skill

Systematic compliance assessment for projects against checkpoint-enabled skills.

## Running the Assessment

```
/assess                              # Assess against all matching skills
/assess skill-repo typo3-testing     # Assess against specific skills only
/assess --force                      # Run all skills, ignore preconditions
/assess --mechanical-only            # Skip LLM reviews, only scripted checks
/assess --autofix                    # Find and fix issues automatically
/assess skill-repo --autofix        # Fix specific skill's issues only
/assess --review                     # Categorize failures as skill improvements
/assess --autoimprove                # Fix + propose skill improvements
/assess dependency-compatibility     # Run dependency compatibility checks
/assess --pre-push                   # Run pre-push validation gate
/assess --check-coverage             # Verify skills have adequate checkpoints
```

### Options

| Flag | Effect |
|------|--------|
| `<skill-names>` | Only run checkpoints for named skills |
| `--force` | Skip precondition checks, run all skills |
| `--mechanical-only` | Skip LLM reviews, only run scripted checks |
| `--autofix` | Fix failures by invoking the responsible skill, then re-verify |
| `--review` | Categorize failures and suggest skill improvements |
| `--autoimprove` | Fix what's possible, propose improvements for the rest |
| `--create-issues` | With --autoimprove, create GitHub issues in skill repos |
| `--json` | Output raw JSON instead of formatted report |
| `--pre-push` | Run pre-push validation gate (PHPStan, tests, CGL, Rector) |
| `--check-coverage` | Verify skills have adequate checkpoint coverage |
| `dependency-compatibility` | Run dependency compatibility assessment |

### Steps

1. Discover matching skills, evaluate preconditions
2. Run scripted checks (mechanical checkpoints)
3. Group LLM checkpoints by domain, spawn parallel agents
4. Collect results and generate compliance report

## Checkpoint Types

**Mechanical:** `file_exists`, `file_not_exists`, `contains`, `not_contains`, `regex`, `json_path`, `gh_api`, `command`. **LLM:** `llm_review` (grouped by domain). See `references/checkpoints-schema.md`.

## Domain Groups

| Domain | Focus |
|--------|-------|
| `repo-health` | README, badges, branding, AGENTS.md |
| `security` | SLSA, OpenSSF, SBOM, vulnerabilities |
| `code-quality` | PHPStan, tests, PHP 8.x patterns |
| `documentation` | RST, rendering, docs.typo3.org |
| `git-workflow` | Branching, commits, conventional commits |
| `docker` | Dockerfile, compose, container patterns |
| `ddev` | DDEV configuration, services, commands |
| `upgrade` | TYPO3 version upgrades, deprecations |
| `dependency-compatibility` | Multi-version dependency API compat, mocks, PHPStan ignores |
| `pre-push` | Local CI validation gate (PHPStan, tests, CGL, Rector) |

## Autofix Workflow

With `--autofix`: run checks, invoke responsible skill for failures (e.g., `/agent-rules`), re-verify. Statuses: `auto-fixed` (now passes), `needs-review` (LLM item), `unfixable` (still fails).

## Review & Improvement

`--review` and `--autoimprove` create a feedback loop from assessment back into skills. Categories: `fixable` (skill can fix), `skill-gap` (propose SKILL.md update), `checkpoint-issue` (miscalibrated check).

`--autoimprove` runs autofix first, then analyzes remaining failures and proposes checkpoint changes. Use `--create-issues` to file issues in skill repos.

## Dependency Compatibility Assessment

Automatically triggered when `composer.json` constraints span multiple major versions (e.g., `^2.0 || ^3.0`). Verifies:

1. All declared major versions can be installed
2. PHPStan passes against each version
3. Unit tests pass against each version
4. API calls are compatible across all versions (method existence, signatures, return types)

See `references/dependency-compatibility.md` for full workflow.

## Checkpoint Coverage Validation

The `--check-coverage` flag verifies that skills have adequate checkpoints for the failure classes they should catch:

- **API compatibility** -- methods exist across all supported dependency versions
- **Test mock validity** -- mocked methods exist on real interfaces
- **PHPStan ignore validity** -- ignore tags are specific and necessary
- **Test assertion specificity** -- assertions catch real regressions

See `references/checkpoint-coverage-requirements.md` for the coverage matrix.

## Pre-Push Validation Gate

The `--pre-push` flag runs all local CI checks and verifies they pass:

| Tool | Checkpoint | Severity |
|------|-----------|----------|
| PHPStan | PP-01 | error |
| PHPUnit | PP-02 | error |
| PHP-CS-Fixer | PP-03 | warning |
| Rector | PP-04 | warning |

Only tools that are installed (`vendor/bin/*` exists) are checked. Missing tools are skipped, not failed.

## Severity Levels

`error` = blocks release, `warning` = recommendation, `info` = optional.

## References

- `references/checkpoints-schema.md` -- checkpoint YAML schema
- `references/checkpoint-workflow.md` -- discovery, agents, validation
- `references/migration-guide.md` -- adding checkpoints to skills
- `references/dependency-compatibility.md` -- multi-version dependency assessment
- `references/checkpoint-coverage-requirements.md` -- skill checkpoint coverage matrix
