---
name: automated-assessment
description: "Use when assessing projects for compliance against Netresearch skill standards, running quality audits, or verifying readiness before release."
---

# Automated Assessment Skill

Systematic compliance assessment for projects against all Netresearch skills.

## Why This Skill Exists

LLMs typically cherry-pick obvious issues and miss 50-80% of requirements. This skill enforces systematic verification through scripted pre-flight checks, domain-batched LLM agents, and structured JSON output.

## Running the Assessment

```
/assess                              # Assess against all matching skills
/assess skill-repo typo3-testing     # Assess against specific skills only
/assess --force                      # Run all skills, ignore preconditions
/assess --mechanical-only            # Skip LLM reviews, only scripted checks
```

### Options

| Flag | Effect |
|------|--------|
| `<skill-names>` | Only run checkpoints for named skills |
| `--force` | Skip precondition checks, run all skills |
| `--mechanical-only` | Skip LLM reviews, only run scripted checks |
| `--json` | Output raw JSON instead of formatted report |

### Steps Performed

1. **Detect project root**
2. **Discover all skills** from plugin cache and local skills
3. **Evaluate preconditions** — skip skills whose preconditions don't match project type
4. **Find checkpoints** using convention-with-override pattern
5. **Run scripted checks** (file_exists, contains, regex, etc.)
6. **Group LLM checkpoints** by domain, spawn 3-4 parallel agents
7. **Collect JSON results** and validate completeness
8. **Generate compliance report**

## Checkpoint Types

For full schema, see `references/checkpoints-schema.md`.

### Mechanical Checks (Scripted)

| Type | Description |
|------|-------------|
| `file_exists` | `test -f $target` |
| `file_not_exists` | `test ! -f $target` |
| `contains` | `grep -q "$pattern" $target` |
| `not_contains` | `! grep -q "$pattern" $target` |
| `regex` | `grep -qE "$pattern" $target` |
| `json_path` | `jq -e "$path" $target` |
| `gh_api` | GitHub API check via `gh api` |
| `command` | Run arbitrary command, check exit code |

### LLM Reviews (Agent)

| Type | Description |
|------|-------------|
| `llm_review` | Requires LLM judgment, grouped by domain |

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
