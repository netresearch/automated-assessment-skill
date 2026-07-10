---
name: my-skill-name
description: "Brief description of what this skill does"
user_invocable: false
# Optional: specify custom checkpoint file location (default: checkpoints.yaml in skill root)
# checkpoints: custom/path/checkpoints.yaml
---

# Skill Name

One paragraph description of the skill's purpose.

## When to Use This Skill

Describe the scenarios when this skill should be activated.

## Core Workflow

Describe the main workflow steps.

## Verification / Claims

Show test output as evidence before claiming work is complete — never say
"try again", "should work now", "tested", "verified", or "all green" without
pasted command output.

The `checkpoints.yaml` shipped with this template enforces this mechanically
(CI-run recency, test-report freshness). The full pattern catalog lives in the
automated-assessment skill's `references/verification-patterns.md`:
https://github.com/netresearch/automated-assessment-skill/blob/main/skills/automated-assessment/references/verification-patterns.md

## Using Reference Documentation

When doing X, consult `references/x-guide.md` for details.

When doing Y, consult `references/y-patterns.md` for examples.

## Running Scripts

To validate something:

```bash
scripts/validate.sh /path/to/project
```

## Using Asset Templates

To set up something, copy `assets/template.yaml` to your project.

## Quick Reference

| Concept | Pattern |
|---------|---------|
| Example | `code example` |

## Pre-Commit Checklist

- [ ] Check 1
- [ ] Check 2
- [ ] Check 3

---

> **Contributing:** https://github.com/netresearch/my-skill-name
