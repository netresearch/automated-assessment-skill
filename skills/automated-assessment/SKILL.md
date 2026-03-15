---
name: automated-assessment
description: "Use when assessing projects for compliance against Netresearch skill standards, running quality audits, or verifying readiness before release."
---

# Automated Assessment Skill

Systematic compliance assessment for projects against all Netresearch skills.

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

## Autofix Workflow

With `--autofix`: run checks, invoke responsible skill for failures (e.g., `/agent-rules`), re-verify. Statuses: `auto-fixed` (now passes), `needs-review` (LLM item), `unfixable` (still fails).

## Review & Improvement

`--review` and `--autoimprove` create a feedback loop from assessment back into skills.

| Category | Meaning | Action |
|----------|---------|--------|
| `fixable` | A skill can fix this | `--autofix` runs the skill |
| `skill-gap` | Skill doesn't cover this | Propose SKILL.md update |
| `checkpoint-issue` | Checkpoint miscalibrated | Propose checkpoint change |

`--autoimprove` runs autofix first, then for remaining failures: analyzes root cause, proposes changes (checkpoint severity/precondition/description), and outputs improvement JSON. Use `--create-issues` to file issues in skill repos.

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `error` | Must fix before release | Blocks release |
| `warning` | Should fix | Recommendation |
| `info` | Nice to have | Optional |

## References

- `references/checkpoints-schema.md` -- checkpoint YAML schema
- `references/checkpoint-workflow.md` -- discovery, agents, validation
- `references/migration-guide.md` -- adding checkpoints to skills
