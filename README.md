# Automated Assessment Skill

[![CI](https://github.com/netresearch/extension-assessment-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/netresearch/extension-assessment-skill/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-MIT%20%2B%20CC--BY--SA--4.0-blue.svg)](#license)

Systematic project assessment against all Netresearch skills with checkpoint-based verification - by Netresearch.

## Why This Skill Exists

When asked to "ensure project aligns with all skills", LLMs typically:
- Cherry-pick obvious issues (satisficing)
- Miss 50-80% of requirements
- Report "done" without exhaustive verification

This skill enforces **systematic verification** through:
1. **Scripted pre-flight checks** (mechanical, 100% accurate)
2. **Domain-batched LLM agents** (subjective judgment)
3. **Structured JSON output** (verifiable completeness)

## Installation

### Via Netresearch Marketplace (Recommended)

```bash
claude plugins:install netresearch/extension-assessment-skill
```

### Via Composer

```bash
composer require netresearch/agent-extension-assessment
```

## Usage

### Run Assessment

```
/assess                              # Assess against all matching skills
/assess skill-repo typo3-testing     # Assess against specific skills only
/assess --force                      # Run all skills, ignore preconditions
/assess --mechanical-only            # Skip LLM reviews, only scripted checks
```

This will:
1. Detect project root
2. Discover all skills with checkpoints
3. Evaluate preconditions — skip skills that don't match project type
4. Run scripted mechanical checks
5. Spawn domain-batched LLM agents for subjective reviews
6. Generate compliance report

### Run Checkpoints Manually

```bash
scripts/run-checkpoints.sh <checkpoints.yaml> <project-root>
```

## Adding Checkpoints to Skills

Create `checkpoints.yaml` in your skill's root directory:

```yaml
version: 1
skill_id: my-skill

mechanical:
  - id: MS-01
    type: file_exists
    target: README.md
    severity: error
    desc: "README.md must exist"

llm_reviews:
  - id: MS-10
    domain: repo-health
    prompt: "Verify README structure follows standards"
    severity: warning
    desc: "README should have standard sections"
```

See `skills/automated-assessment/references/checkpoints-schema.md` for full schema documentation.

## Checkpoint Types

| Type | Description |
|------|-------------|
| `file_exists` | File must exist |
| `file_not_exists` | File must NOT exist |
| `contains` | File contains literal string |
| `regex` | File matches regex pattern |
| `json_path` | JSON path exists (jq) |
| `command` | Command exits with 0 |
| `llm_review` | Requires LLM judgment |

## Domain Groups

| Domain | Focus |
|--------|-------|
| `repo-health` | README, badges, branding, AGENTS.md |
| `security` | SLSA, OpenSSF, SBOM, vulnerabilities |
| `code-quality` | PHPStan, tests, PHP patterns |
| `documentation` | RST, docs.typo3.org standards |
| `git-workflow` | Branching, commits, tags, conventional commits |
| `docker` | Dockerfile, compose, container patterns |
| `ddev` | DDEV configuration, services, commands |
| `upgrade` | TYPO3 version upgrades, deprecations |

## Example Assessment Output

```json
{
  "project": "netresearch/contexts",
  "overall_status": "FAIL",
  "summary": {
    "total": 45,
    "pass": 38,
    "fail": 5,
    "skip": 2
  },
  "checkpoints": [
    {"id": "GH-01", "status": "pass", "evidence": "README.md exists"},
    {"id": "ER-04", "status": "fail", "evidence": "Missing OpenSSF badge"}
  ]
}
```

## Assets

- `assets/github-project-checkpoints.yaml` - Example checkpoints for github-project skill
- `assets/enterprise-readiness-checkpoints.yaml` - Example checkpoints for enterprise-readiness skill
- `assets/llm-rubric-repo-health.md` - LLM review rubrics for repo-health domain
- `assets/skill-template/` - Template for creating new skills with checkpoints

## References

- `references/checkpoints-schema.md` - Full schema documentation
- `references/migration-guide.md` - How to add checkpoints to existing skills

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

This project uses split licensing:

- **Code** (scripts, workflows, configs): [MIT](LICENSE-MIT)
- **Content** (skill definitions, documentation, references): [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0)

See the individual license files for full terms.
---

> **Netresearch DTT GmbH** - [netresearch.de](https://www.netresearch.de/)
