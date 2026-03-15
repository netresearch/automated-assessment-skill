---
name: add-checkpoints
description: "Use when adding assessment checkpoints to a skill, evaluating whether a skill is suitable for checkpoints, or generating checkpoint YAML from skill requirements."
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
6. **Validate** — run `scripts/run-checkpoints.sh` against a sample project to verify
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

Report suitability with reasoning so the user can decide.

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

### LLM Reviews

For subjective requirements that can't be mechanically verified:
- Code quality judgments → `domain: code-quality`
- Documentation completeness → `domain: documentation`
- Architecture decisions → `domain: architecture`

Group by domain, provide clear rubric prompts.

## Output

Generates `checkpoints.yaml` in the skill's directory following the schema at `references/checkpoints-schema.md`. Also creates a copy in the automated-assessment assets directory.

## References

- Schema: `references/checkpoints-schema.md`
- Migration guide: `references/migration-guide.md`
- Existing checkpoints: `assets/*-checkpoints.yaml` (as examples)
