# Migration Guide: Adding Checkpoints to Skills

This guide explains how to add checkpoints to existing skills for automated assessment.

## Overview

The extension-assessment skill uses **checkpoints** to systematically verify TYPO3 extensions against all skills. Checkpoints are either:

1. **Mechanical** - Script-runnable checks (file exists, contains pattern, etc.)
2. **LLM Reviews** - Subjective checks requiring agent judgment

## Migration Steps

### Step 1: Create checkpoints.yaml

In your skill's root directory, create `checkpoints.yaml`:

```yaml
version: 1
skill_id: your-skill-name

mechanical:
  - id: YS-01
    type: file_exists
    target: README.md
    severity: error
    desc: "README.md must exist"

llm_reviews:
  - id: YS-10
    domain: repo-health
    prompt: "Verify README follows skill guidelines"
    severity: warning
    desc: "README should follow standards"
```

### Step 2: Choose Checkpoint IDs

Use a consistent prefix based on your skill name:

| Skill | Prefix | Example |
|-------|--------|---------|
| github-project | GH | GH-01, GH-02 |
| enterprise-readiness | ER | ER-01, ER-02 |
| typo3-conformance | TC | TC-01, TC-02 |
| typo3-testing | TT | TT-01, TT-02 |
| agents | AG | AG-01, AG-02 |
| php-modernization | PM | PM-01, PM-02 |
| security-audit | SA | SA-01, SA-02 |
| typo3-docs | TD | TD-01, TD-02 |

### Step 3: Convert Requirements to Checkpoints

For each requirement in your skill, determine the checkpoint type:

| Requirement Type | Checkpoint Type | Example |
|------------------|-----------------|---------|
| "File X must exist" | `file_exists` | `target: SECURITY.md` |
| "File X should NOT exist" | `file_not_exists` | `target: .env` |
| "File contains text Y" | `contains` | `pattern: "codecov.io"` |
| "File matches pattern Y" | `regex` | `pattern: "uses: [^@]+@[a-f0-9]{40}"` |
| "JSON has path X" | `json_path` | `pattern: '.require["php"]'` |
| "Command succeeds" | `command` | `pattern: "composer validate"` |
| "Subjective judgment" | `llm_review` | `domain: code-quality` |

### Step 4: Assign Severity Levels

| Severity | Use When |
|----------|----------|
| `error` | Must fix before release, blocks deployment |
| `warning` | Should fix, strong recommendation |
| `info` | Nice to have, optional improvement |

### Step 5: Create LLM Rubric (Optional)

For complex LLM reviews, create a rubric file in `references/`:

```markdown
# references/llm-rubric.md

## badge-order

### Checkpoint: Verify Badge Ordering

**Requirement:** Badges must appear in standard order.

**Expected Order:**
1. CI badges
2. Security badges
3. Standards badges
4. TER badges

**Evaluation:**
| Status | Condition |
|--------|-----------|
| pass | Badges follow expected order |
| fail | Badges are out of order |
| skip | No badges present |
```

Reference it in checkpoints.yaml:

```yaml
llm_reviews:
  - id: GH-15
    domain: repo-health
    rubric: references/llm-rubric.md#badge-order
    severity: warning
```

### Step 6: Test Your Checkpoints

Run the checkpoint runner on a test project:

```bash
~/.claude/skills/extension-assessment/scripts/run-checkpoints.sh \
  /path/to/your/skill/checkpoints.yaml \
  /path/to/test/project
```

### Step 7: Verify Checkpoint Coverage

Ensure all key requirements from your skill have corresponding checkpoints:

1. Read through your SKILL.md
2. List all explicit requirements
3. Map each to a checkpoint
4. Check for gaps

## Example Migration: github-project Skill

### Before (Requirements in SKILL.md)

```markdown
## Required Files
- README.md (required)
- LICENSE (required)
- SECURITY.md (recommended)
- CODEOWNERS (recommended)

## Badge Requirements
- CI status badge
- Codecov badge
- License badge
```

### After (checkpoints.yaml)

```yaml
version: 1
skill_id: github-project

mechanical:
  - id: GH-01
    type: file_exists
    target: README.md
    severity: error
    desc: "README.md must exist"

  - id: GH-02
    type: file_exists
    target: LICENSE
    severity: error
    desc: "LICENSE file must exist"

  - id: GH-03
    type: file_exists
    target: SECURITY.md
    severity: warning
    desc: "SECURITY.md should exist"

  - id: GH-04
    type: file_exists
    target: .github/CODEOWNERS
    severity: warning
    desc: "CODEOWNERS should exist"

  - id: GH-05
    type: regex
    target: README.md
    pattern: "github.com/.*/actions/workflows"
    severity: error
    desc: "README should have CI badge"

  - id: GH-06
    type: contains
    target: README.md
    pattern: "codecov.io"
    severity: warning
    desc: "README should have Codecov badge"
```

## Rollout Plan

### Phase 1: Pilot Skills
Add checkpoints to 3 skills:
- github-project
- enterprise-readiness
- agents

### Phase 2: Test Assessment
Run `/assess-extension` on contexts extension to validate the system.

### Phase 3: Remaining Skills
Add checkpoints to all other skills:
- typo3-conformance
- typo3-testing
- php-modernization
- security-audit
- typo3-docs
- netresearch-branding

### Phase 4: CI Integration
Add assessment to CI pipeline to run on every PR.

## Troubleshooting

### "Checkpoint runner can't find my checkpoints.yaml"

Ensure the file is in the skill root directory, or specify the path in SKILL.md front matter:

```yaml
---
name: my-skill
checkpoints: custom/path/checkpoints.yaml
---
```

### "My regex pattern isn't matching"

The script uses `grep -E` (extended regex). Test your pattern:

```bash
grep -qE "your-pattern" /path/to/file && echo "Match" || echo "No match"
```

### "JSON path check fails"

The script uses `jq`. Test your path:

```bash
jq -e '.your.path' /path/to/file.json
```

### "LLM review domain not recognized"

Valid domains: `repo-health`, `security`, `code-quality`, `documentation`
