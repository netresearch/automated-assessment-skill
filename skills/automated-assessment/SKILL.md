---
name: automated-assessment
description: "Use when assessing projects for compliance against Netresearch skill standards, running quality audits, or verifying readiness before release."
---

# Automated Assessment Skill

Systematic compliance assessment for projects against all Netresearch skills.

## Why This Skill Exists

LLMs cherry-pick obvious issues and miss 50-80% of requirements. This skill enforces systematic verification through scripted checks, domain-batched LLM agents, and structured JSON output.

## Running the Assessment

```
/assess                              # Assess against all matching skills
/assess skill-repo typo3-testing     # Assess against specific skills only
/assess --force                      # Run all skills, ignore preconditions
/assess --mechanical-only            # Skip LLM reviews, only scripted checks
/assess --autofix                    # Find and fix issues automatically
/assess skill-repo --autofix        # Fix specific skill's issues only
```

### Options

| Flag | Effect |
|------|--------|
| `<skill-names>` | Only run checkpoints for named skills |
| `--force` | Skip precondition checks, run all skills |
| `--mechanical-only` | Skip LLM reviews, only run scripted checks |
| `--autofix` | Fix failures by invoking the responsible skill, then re-verify |
| `--json` | Output raw JSON instead of formatted report |

### Steps Performed

1. Detect project root and discover matching skills
2. Evaluate preconditions — skip non-matching skills
3. Run scripted checks (mechanical checkpoints)
4. Group LLM checkpoints by domain, spawn parallel agents
5. Collect results and generate compliance report

## Checkpoint Types

**Mechanical:** `file_exists`, `file_not_exists`, `contains`, `not_contains`, `regex`, `json_path`, `gh_api`, `command` — scripted checks with deterministic pass/fail.

**LLM:** `llm_review` — requires LLM judgment, grouped by domain.

Full schema in `references/checkpoints-schema.md`.

## Domain Groups for LLM Agents

| Domain | Skills | Focus |
|--------|--------|-------|
| `repo-health` | github-project, netresearch-branding, agents | README, badges, branding, AGENTS.md |
| `security` | enterprise-readiness, security-audit | SLSA, OpenSSF, SBOM, vulnerabilities |
| `code-quality` | typo3-conformance, php-modernization, typo3-testing | PHPStan, tests, PHP 8.x patterns |
| `documentation` | typo3-docs | RST, rendering, docs.typo3.org standards |
| `git-workflow` | git-workflow | Branching, commits, tags, conventional commits |
| `docker` | docker-development | Dockerfile, compose, container patterns |
| `ddev` | typo3-ddev | DDEV configuration, services, commands |
| `upgrade` | typo3-extension-upgrade | TYPO3 version upgrades, deprecations |

## Autofix Workflow

When `--autofix` is used:

1. Run mechanical checks as normal
2. For each skill with failures, invoke its slash command (e.g., `/agent-rules`)
3. Re-run failed checkpoints to verify fixes
4. Report results:

| Status | Meaning |
|--------|---------|
| `auto-fixed` | Skill ran and checkpoint now passes |
| `needs-review` | LLM review item — run skill manually |
| `unfixable` | Checkpoint still fails after skill ran |

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `error` | Must fix before release | Blocks release |
| `warning` | Should fix | Recommendation |
| `info` | Nice to have | Optional |

## References

- `references/checkpoints-schema.md` -- full YAML schema for checkpoint definitions
- `references/checkpoint-workflow.md` -- discovery, agent prompts, validation rules
- `references/migration-guide.md` -- adding checkpoints to skills

---

> **Contributing:** Report issues at https://github.com/netresearch/automated-assessment-skill
