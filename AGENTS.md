# AGENTS.md

## Overview

The **automated-assessment** skill provides systematic project compliance assessment against all installed Netresearch skills. It uses scripted verification (mechanical checks) and domain-batched LLM review to ensure no requirement is missed.

## Key Files

| Path | Purpose |
|------|---------|
| `skills/automated-assessment/SKILL.md` | AI skill instructions — the `/assess` command |
| `skills/automated-assessment/scripts/run-checkpoints.sh` | Mechanical checkpoint runner (bash) |
| `skills/automated-assessment/assets/*.yaml` | Checkpoint definitions for each skill |
| `skills/automated-assessment/assets/llm-rubric-repo-health.md` | LLM review rubrics (repo-health domain) |
| `skills/automated-assessment/assets/llm-rubric-dependency-compatibility.md` | LLM review rubrics (dependency-compatibility, pre-push domains) |
| `skills/automated-assessment/references/checkpoints-schema.md` | Checkpoint YAML schema |
| `skills/automated-assessment/references/checkpoint-workflow.md` | Full assessment workflow |
| `skills/automated-assessment/references/migration-guide.md` | Adding checkpoints to new skills |
| `skills/automated-assessment/references/dependency-compatibility.md` | Multi-version dependency assessment workflow |
| `skills/automated-assessment/references/checkpoint-coverage-requirements.md` | Minimum checkpoint coverage per skill domain |
| `.claude-plugin/plugin.json` | Plugin metadata (version, skills path) |

## Architecture

### Checkpoint Discovery

Checkpoints live in each skill's own directory (convention: `skills/{name}/checkpoints.yaml`). The assessment skill discovers them by scanning all installed skills in the plugin cache.

### Preconditions

Each checkpoint file can declare `preconditions:` — conditions that must ALL pass before any checks in that skill run. If a precondition fails, the entire skill is silently skipped. This replaces the old hardcoded project-type detection.

### Two-Tier Verification

1. **Mechanical checks** — scripted file/content/command checks via `run-checkpoints.sh`
2. **LLM reviews** — subjective quality checks grouped by domain, run as parallel agents

### CLI

```bash
/assess                          # All matching skills
/assess skill-repo typo3-testing # Specific skills only
/assess --force                  # Ignore preconditions
/assess --mechanical-only        # Skip LLM reviews
/assess dependency-compatibility # Multi-version dependency checks
/assess --pre-push               # Local CI validation gate
/assess --check-coverage         # Verify checkpoint coverage
```

## Commands

```bash
# Run mechanical checkpoint verification against a project
bash skills/automated-assessment/scripts/run-checkpoints.sh <checkpoints.yaml> <project-root>

# Run the full assessment via Claude Code slash command
/assess                          # All matching skills
/assess skill-repo typo3-testing # Specific skills only
/assess --force                  # Ignore preconditions
/assess --mechanical-only        # Skip LLM reviews
/assess dependency-compatibility # Multi-version dependency checks
/assess --pre-push               # Local CI validation gate
/assess --check-coverage         # Verify checkpoint coverage

# Verify agent harness compliance
bash scripts/verify-harness.sh --format=text --status
```

## Conventions

- **Licensing**: MIT (code) + CC-BY-SA-4.0 (content)
- **Checkpoint IDs**: `{PREFIX}-{NUMBER}` (SR- for skill-repo, GH- for github-project, DC- for dependency-compatibility, PP- for pre-push, etc.)
- **Severity levels**: `error` (blocks release), `warning` (recommendation), `info` (optional)
- **Entity name**: "Netresearch DTT GmbH" in all metadata and license files
