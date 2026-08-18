---
name: add-checkpoints
description: "Use when adding assessment checkpoints to a skill, evaluating checkpoint suitability, or generating checkpoint YAML from skill requirements. Activate on 'add checkpoints', 'generate checkpoints', or checkpoint schema tasks."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
metadata:
  author: Netresearch DTT GmbH
  version: "2.15.1"
  repository: https://github.com/netresearch/automated-assessment-skill
---

# Add Checkpoints to a Skill

Analyze a skill and generate appropriate `checkpoints.yaml` for the automated-assessment framework.

## Command

```
/add-checkpoints                    # Analyze current skill directory
/add-checkpoints typo3-docs         # Analyze a specific installed skill
/add-checkpoints --dry-run          # Show what would be generated, don't write
```

## Workflow

1. **Locate the skill** — find SKILL.md, references/, scripts/, assets/
2. **Analyze suitability** — determine if checkpoints make sense (see criteria below)
3. **Extract requirements** — parse SKILL.md for verifiable rules and patterns
4. **Generate checkpoints** — create `checkpoints.yaml` with mechanical checks and LLM reviews
5. **Add preconditions** — determine which project types this skill applies to
6. **Validate** — `scripts/validate-checkpoints.sh`, then `run-checkpoints.sh` on a sample project
7. **Report** — explain what was generated and why, or why checkpoints don't fit

## Suitability Criteria

A skill is **suitable** for checkpoints if it defines:
- File structure requirements (directories, config files, manifests)
- Content patterns (must contain X, must not contain Y)
- Naming conventions (prefixes, suffixes, case rules)
- Tool configurations (PHPStan level, linter rules, CI steps)
- Metadata standards (license, author, version format)

A skill is **NOT suitable** if it only provides:
- Conceptual guidance without verifiable outputs
- Interactive workflows with no persistent artifacts
- Runtime behavior patterns (performance, caching strategies)

Report suitability with reasoning.

## Checkpoint Generation Rules

### Mechanical Checks

Extract from SKILL.md patterns like:
- "must exist" / "required" → `file_exists`
- "must not" / "never" / "avoid" → `file_not_exists` or `not_contains`
- "must contain" / "should have" → `contains` or `regex`
- Version/format constraints → `json_path` or `command`

### Preconditions

Derive from the skill's scope:
- TYPO3 extensions → `file_exists: ext_emconf.php`
- Docker projects → `file_exists: Dockerfile`
- Go projects → `file_exists: go.mod`
- Skill repos → `file_exists: .claude-plugin/plugin.json`
- Universal (any project) → no preconditions

### ID Convention

Use the skill's established prefix from `references/migration-guide.md`, or derive a 2-letter prefix from the skill name.

### Severity Assignment

- `error`: "must", "required", "never" → blocks release
- `warning`: "should", "recommended" → suggestion
- `info`: "consider", "nice to have" → optional

### Calibration Anchor

Each checkpoint records its predicted defect class and retirement condition as YAML comments. Caps at `info` if missing. See `automated-assessment/references/calibration.md`.

### LLM Reviews

Only for what no command can decide. A prompt opening a line with a command
belongs in `mechanical`; keep both halves only with `# mechanical-counterpart: <ID>`.

- Code quality judgments → `domain: code-quality`
- Documentation completeness → `domain: documentation`
- Architecture decisions → `domain: architecture`

## Output

Generates `checkpoints.yaml` in the skill's directory (schema: `references/checkpoints-schema.md`), plus a copy in the assets directory.

## References

- Schema: `references/checkpoints-schema.md`
- Migration guide: `references/migration-guide.md`
- Existing checkpoints: `assets/*-checkpoints.yaml` (as examples)
