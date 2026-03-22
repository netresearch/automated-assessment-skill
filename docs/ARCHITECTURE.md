# Architecture

## System Overview

The automated-assessment skill provides systematic project compliance verification against all installed Netresearch skills. It combines scripted mechanical checks with LLM-powered subjective reviews.

## Components

### Checkpoint Engine (`skills/automated-assessment/scripts/run-checkpoints.sh`)

Bash script that parses checkpoint YAML definitions and executes mechanical checks (file existence, content matching, regex, JSON path, command execution). Returns structured JSON results.

### Checkpoint Definitions (`skills/automated-assessment/assets/*.yaml`)

YAML files defining checkpoints per skill domain. Each file declares preconditions, mechanical checks, and LLM review prompts. Schema documented in `skills/automated-assessment/references/checkpoints-schema.md`.

### LLM Review Rubrics (`skills/automated-assessment/assets/llm-rubric-*.md`)

Markdown rubrics that guide LLM agents during subjective quality reviews. Grouped by domain (repo-health, security, code-quality, etc.).

### Add-Checkpoints Skill (`skills/add-checkpoints/`)

Helper skill for creating new checkpoint definitions in other skill repos.

## Data Flow

```
/assess command
  -> Discover installed skills with checkpoints.yaml
  -> Evaluate preconditions (skip non-matching project types)
  -> Run mechanical checks via run-checkpoints.sh
  -> Spawn parallel LLM agents for subjective reviews
  -> Aggregate results into structured JSON report
```

## Key Design Decisions

- **Two-tier verification**: Mechanical checks catch deterministic issues; LLM reviews handle subjective quality assessments.
- **Preconditions**: Each checkpoint file can declare conditions to skip irrelevant skills (e.g., PHP-only checks skip Node projects).
- **Domain batching**: LLM reviews are grouped by domain to reduce context switching and improve review quality.
