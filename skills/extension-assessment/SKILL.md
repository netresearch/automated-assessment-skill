---
name: extension-assessment
description: "Use when assessing TYPO3 extensions for compliance against all Netresearch skills, or running /assess-extension for systematic verification with scripted checks and domain-batched LLM review."
user_invocable: true
---

# Extension Assessment Skill

Systematic compliance assessment for TYPO3 extensions against all Netresearch skills.

## Why This Skill Exists

When asked to "ensure extension aligns with all skills", LLMs typically cherry-pick obvious issues and miss 50-80% of requirements. This skill enforces systematic verification through scripted pre-flight checks (mechanical, 100% accurate), domain-batched LLM agents (subjective judgment), and structured JSON output (verifiable completeness).

## Running the Assessment

```
/assess-extension
```

Steps performed:

1. **Detect extension root** (ext_emconf.php or composer.json with typo3-cms-extension)
2. **Discover all skills** from plugin cache and local skills
3. **Find checkpoints** using convention-with-override pattern
4. **Run scripted checks** (file_exists, contains, regex, etc.)
5. **Group LLM checkpoints** by domain, spawn 3-4 parallel agents
6. **Collect JSON results** and validate completeness
7. **Generate compliance report**

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

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `error` | Must fix before release | Blocks release |
| `warning` | Should fix | Recommendation |
| `info` | Nice to have | Optional |

## Using Reference Documentation

- **Checkpoints schema**: `references/checkpoints-schema.md` -- full YAML schema for checkpoint definitions
- **Checkpoint workflow**: `references/checkpoint-workflow.md` -- discovery, agent prompts, validation rules, YAML format, troubleshooting
- **Migration guide**: `references/migration-guide.md` -- guide for adding checkpoints to skills that don't have them yet

---

> **Contributing:** Report issues at https://github.com/netresearch/extension-assessment-skill
