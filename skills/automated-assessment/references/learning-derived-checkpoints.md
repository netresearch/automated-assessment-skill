# Learning-derived Checkpoints

How **`checkpoint` destination** materializations from `retro-skill` translate into entries in a target skill's `checkpoints.yaml`. This document is the contract between `retro-skill` (which proposes checkpoints) and `automated-assessment-skill` (which defines the YAML schema and the verifier runtime).

## When this applies

A friction finding routes to `checkpoint` destination when:

- The rule is **mechanically detectable** (regex, file presence, command exit code)
- It can be checked **without LLM reasoning**
- It enforces a **stable, project-scoped or skill-scoped invariant**

If the rule needs context understanding → `skill-update` instead.
If the rule needs to fire pre-action (e.g. pre-commit) → `harness-artefact` instead.

## YAML schema (per `references/checkpoints-schema.md`)

A learning-derived checkpoint follows the existing schema:

```yaml
- id: <PREFIX>-<NN>
  type: file_exists | regex | command
  target: <path or glob>
  value: <pattern>          # for regex type
  pattern: <command>        # for command type
  severity: error | warning | info
  desc: "<what the check enforces>"
```

### ID convention

`<PREFIX>` is the target skill's existing checkpoint prefix (e.g. `AH-` for agent-harness, `RT-` for retro). `<NN>` continues that skill's numbering (Level 1: 01-09, Level 2: 10-19, Level 3: 20-29, Level 3+: 30-39).

`retro-skill` MUST grep the existing `checkpoints.yaml` for the highest used ID in the target level range and assign the next free number. Document the decision in the PR body.

### Severity guidance

| Severity | When |
|---|---|
| `error` | Violation breaks the skill or repo integrity |
| `warning` | Violation degrades quality but skill still works |
| `info` | Aspirational / nice-to-have / informational |

Learning-derived checkpoints **default to `warning`** unless the friction caused upstream failure (then `error`) or is purely informational (then `info`).

## Three check types

### 1. `file_exists`

```yaml
- id: <PREFIX>-NN
  type: file_exists
  target: <path or brace-expansion glob>
  severity: warning
  desc: "<artefact> must exist for <reason>"
```

Use when: the friction was caused by a missing file (template, hook, doc).

Example (derived from "PR template missing retro question"):
```yaml
- id: AH-22
  type: regex
  target: "{.github/pull_request_template.md,.github/PULL_REQUEST_TEMPLATE/*}"
  value: "(?i)retro|reusable.*pattern"
  severity: warning
  desc: "PR/MR template includes retro question for agent-authored work"
```

### 2. `regex`

```yaml
- id: <PREFIX>-NN
  type: regex
  target: <path>
  value: <regex pattern>
  severity: warning
  desc: "<file> must contain <pattern>"
```

Use when: the friction was caused by missing or wrong content in a known file.

### 3. `command`

```yaml
- id: <PREFIX>-NN
  type: command
  pattern: "<shell command that exits 0 on pass>"
  severity: warning
  desc: "<what the command verifies>"
```

Use when: the check is more complex than regex (multi-file, conditional, requires parsing).

The command MUST:
- Exit 0 on pass, non-zero on fail
- Run quickly (<2s ideally)
- Have no side effects
- Be reproducible (no random/time-dependent state)

## Workflow for retro-skill

When `retro-skill` proposes a `checkpoint` destination:

1. **Locate target skill's `checkpoints.yaml`** (via discovery → repo URL → clone/worktree)
2. **Grep existing IDs** in the target level range (warning → 20-29, error → 10-19, etc.)
3. **Assign next free ID** with appropriate prefix
4. **Choose check type** (file_exists / regex / command)
5. **Draft YAML entry** matching this contract
6. **Include in PR body:**
   - Friction signal that triggered this
   - Why this is mechanically checkable (vs needing LLM)
   - Why this severity level
   - Why this check type
7. **Run target skill's verifier** locally to confirm the new checkpoint actually fires for the friction case
8. **Eval stub:** if the target skill supports evals, include a regression eval

## Eval stub (TDD-style)

When proposing a checkpoint, also include a regression eval if the skill has `evals/`:

```markdown
---
scenario: regression-AH-22
trigger: PR template lacks retro question
expected: AH-22 fires with severity=warning
---
```

This is the TDD pattern: checkpoint that detects the friction goes in alongside an eval that proves the checkpoint works.

## Anti-patterns

- **Too narrow:** Checkpoint that only catches one specific historical case (e.g. matches a unique string). Generalize the regex.
- **Too broad:** Checkpoint that fires on unrelated content. Tighten the regex.
- **LLM-needed:** Checkpoint described as "the file should have good prose". That's not mechanical — route to `skill-update`.
- **Wrong severity:** `error` for a stylistic preference. Use `warning` or `info`.
- **No eval:** Adding a checkpoint without proving it works. Always smoke-test.

## See also

- `references/checkpoints-schema.md` — Full YAML schema reference
- `references/checkpoint-workflow.md` — How verifier runtime processes checkpoints
- `references/verification-patterns.md` — Common verification patterns
- `retro-skill/references/destination-taxonomy.md` — Where this fits in retro's 6 destinations
- `retro-skill/references/classification-heuristic.md` — Friction → checkpoint mapping
