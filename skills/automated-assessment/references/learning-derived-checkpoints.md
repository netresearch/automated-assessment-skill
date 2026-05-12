# Learning-derived Checkpoints

How **`checkpoint` destination** materializations from `retro-skill` translate into entries in a target skill's `checkpoints.yaml`. This document is the contract between `retro-skill` (which proposes checkpoints) and `automated-assessment-skill` (which defines the YAML schema and the verifier runtime).

**Authoritative schema source:** `references/checkpoints-schema.md`. This document only describes the routing-from-retro contract; field definitions live in the schema reference.

## When this applies

A friction finding routes to the `checkpoint` destination when **all** of the following hold:

- The rule is **mechanically detectable** (regex, file presence, command exit code, JSON/YAML path query)
- It can be checked **without LLM reasoning**
- It enforces a **stable, project-scoped or skill-scoped invariant**

If the rule needs context understanding → route to **`llm_reviews`** (see schema §LLM Review Fields). The retro-skill destination is `skill-update` *only* when the change is to the skill's prose, templates, or scripts. LLM-judgable but mechanically expressed rules belong in `llm_reviews:` inside `checkpoints.yaml`, **not** in the mechanical list and **not** as a `skill-update`.

If the rule needs to fire pre-action (e.g. pre-commit) → `harness-artefact` destination instead.

If the rule depends on environment (PHP project, Node project) → consider `preconditions:` block (schema §Preconditions) rather than a brittle conditional in the check itself.

## YAML schema (canonical reference)

The authoritative schema is in `references/checkpoints-schema.md`. A checkpoint entry has these fields:

```yaml
- id: <PREFIX>-<NN>                   # e.g. AH-22, SR-15, RT-10
  type: <one of 10 types — see below>
  target: <path or glob>              # Required for most types; not for `command`
  pattern: <regex|jq path|yq path|shell command>
  severity: error | warning | info
  desc: "<what the check enforces>"
  fix_skill: <skill-id>               # Optional; overrides default fix routing
```

### Field names by type

| Type | Required | Notes |
|---|---|---|
| `file_exists`, `file_not_exists` | `target` | No `pattern` |
| `contains`, `not_contains` | `target`, `pattern` (literal string) | |
| `regex`, `regex_not` | `target`, `pattern` (regex) | Field is `pattern:`, NOT `value:` |
| `json_path` | `target`, `pattern` (jq path expression) | |
| `yaml_path` | `target`, `pattern` (yq path expression) | |
| `gh_api` | `endpoint`, plus `expect_contains` or `json_path` | |
| `command` | `pattern` (the shell command) | No `target` |

The historical `value:` field appears in a few older `agent-harness` AH-* entries; the canonical schema uses `pattern:` everywhere. New learning-derived checkpoints MUST use `pattern:` and the schema-canonical names. Don't propagate the `value:` legacy.

## ID convention

`<PREFIX>` is the target skill's existing checkpoint prefix (e.g. `AH-` for `agent-harness`, `SR-` for `skill-repo`, `RT-` for `retro-skill`). `<NN>` is the next free number.

**There is no universal severity→ID-range mapping.** Each skill chooses its own numbering policy:

- Some skills (e.g. `agent-harness`) band IDs by maturity level: 01-09 = Level 1, 10-19 = Level 2, 20-29 = Level 3.
- Other skills (e.g. `skill-repo`) run a flat sequence (SR-01 through SR-NN) with no level grouping.

`retro-skill` MUST:

1. Inspect the target skill's existing `checkpoints.yaml`.
2. Identify the numbering convention in use.
3. Pick the next free ID matching that convention.
4. Document the choice in the PR body so reviewers see the reasoning.

Format the ID as `<PREFIX>-<NN>` (single hyphen between prefix and number). Don't write `<PREFIX>NN` (no hyphen) or `<PREFIX>--<NN>` (double hyphen).

## Severity guidance

| Severity | When |
|---|---|
| `error` | Violation breaks the skill or repo integrity |
| `warning` | Violation degrades quality but skill still works |
| `info` | Aspirational, nice-to-have, or informational |

Learning-derived checkpoints **default to `warning`** unless:

- The friction caused upstream failure (CI break, push rejection) → `error`
- The check is purely informational or optional → `info`

Severity is independent of ID range. Setting severity wrong is a more common failure than picking the wrong ID.

## `fix_skill` field (routing autofix)

```yaml
fix_skill: retro
```

When present, `fix_skill` overrides the default `skill_id` for autofix routing. Set it when the checkpoint lives in skill A but the fix is owned by skill B.

For retro-skill-proposed checkpoints, `fix_skill` is usually appropriate when:

- A friction in skill A pointed to a missing convention enforced by skill B
- E.g. `agent-harness/checkpoints.yaml` has `AH-22: PR template includes retro question` with `fix_skill: retro` (because retro-skill knows how to add the template content)

## `llm_reviews:` routing

A checkpoint that requires LLM judgment lives in `llm_reviews:` (top-level list in `checkpoints.yaml`, not in `mechanical:`). See schema §LLM Review Fields.

Example:

```yaml
llm_reviews:
  - id: SR-LLM-01
    target: skills/skill-repo/SKILL.md
    prompt: "Does this SKILL.md trigger description include enough specific verbs for an agent to recognize when to invoke it?"
    severity: warning
```

retro-skill should propose to `llm_reviews:` (not `mechanical:`) when the friction is "the file says X but should clearly imply Y" — judgment, not pattern matching.

## File structure (complete picture)

A `checkpoints.yaml` is a complete YAML file with this top-level structure (per schema §Full Schema):

```yaml
version: 1
skill_id: <skill-name>
preconditions:                       # Optional gate: skill only applies if these hold
  - type: file_exists
    target: ext_emconf.php
mechanical:                          # List of mechanical checks
  - id: <PREFIX>-<NN>
    type: ...
    ...
llm_reviews:                         # Optional list of LLM-judged checks
  - id: <PREFIX>-LLM-<NN>
    ...
```

retro-skill MUST APPEND to the existing `mechanical:` (or `llm_reviews:`) list inside the existing file. Don't emit a fragment of YAML with no version/skill_id — that won't parse as a checkpoints file.

## Three common check patterns (with examples)

### `file_exists` — artefact must be present

Use when: friction caused by missing file (template, hook, doc).

```yaml
- id: AH-23
  type: file_exists
  target: "{.claude/hooks/session-end.json,hooks/session-end.json}"
  severity: info
  desc: "SessionEnd hook configured (optional)"
  fix_skill: retro
```

### `regex` — file must contain a pattern

Use when: file must contain specific content.

```yaml
- id: SR-NN
  type: regex
  target: skills/skill-repo/SKILL.md
  pattern: "^## When to use this skill"
  severity: warning
  desc: "SKILL.md has a 'When to use' section"
```

### `command` — complex multi-file or scripted check

Use when: the check is conditional or spans multiple files.

```yaml
- id: AH-22
  type: command
  pattern: "grep -liE '(retro|reusable.*pattern)' .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE/*.md .gitlab/merge_request_templates/*.md 2>/dev/null | head -1 | grep -q ."
  severity: warning
  desc: "PR/MR template includes retro question for agent-authored work"
  fix_skill: retro
```

The command MUST exit 0 on pass, non-zero on fail, run fast (<2s), have no side effects, and be deterministic (no time/random state).

## Workflow for retro-skill

When `/retro` proposes a `checkpoint` destination:

1. **Locate** target skill's `checkpoints.yaml` (via discovery → repo URL → clone/worktree).
2. **Read** the existing file: identify `skill_id`, existing IDs, numbering convention.
3. **Choose** check type from the 10 canonical types (prefer `file_exists`/`contains`/`regex` over `command` when possible).
4. **Assign** next free ID matching the existing convention.
5. **Set** severity per guidance above.
6. **Set** `fix_skill` if the fix is owned by a different skill than the one hosting the checkpoint.
7. **Draft** the YAML block aligned with `references/checkpoints-schema.md`.
8. **Append** to `mechanical:` (or `llm_reviews:` if LLM-judged) — do NOT emit a YAML fragment standalone.
9. **Document** in the PR body: friction signal, why this is mechanically checkable, why this severity, why this type.
10. **Run** the assessment verifier locally:
    ```bash
    # In automated-assessment-skill or via skill's local validator
    bash skills/automated-assessment/scripts/validate-checkpoints.sh <path-to-checkpoints.yaml>
    ```
    Confirm the new entry parses and the new checkpoint actually fires for the friction case.
11. **Eval stub:** if the target skill supports evals, include a regression eval. The eval format is skill-specific — read the target's existing `evals/` to match its convention.

## Anti-patterns

- **Field name `value:` for regex/contains** — schema uses `pattern:`. Don't perpetuate the legacy.
- **Severity-to-ID-range mapping** — each skill chooses its own ID policy; don't impose `error → 10-19, warning → 20-29` universally.
- **Standalone YAML fragments** — checkpoints live inside a `mechanical:` or `llm_reviews:` list within a complete file; retro must append, not emit standalone.
- **`mechanical:` for LLM-judgable rules** — route to `llm_reviews:` instead.
- **Too narrow** — checkpoint that matches one historical case (e.g. matches a unique string). Generalize.
- **Too broad** — checkpoint that fires on unrelated content. Tighten.
- **Missing `fix_skill`** when the fix lives elsewhere — autofix will route to the wrong skill.
- **No verification step** — adding a checkpoint without running the verifier locally to prove it fires.

## See also

- `references/checkpoints-schema.md` — Full YAML schema reference (authoritative; this doc only describes routing)
- `references/checkpoint-workflow.md` — How the verifier runtime processes checkpoints
- `references/verification-patterns.md` — Common verification patterns
- [retro-skill destination-taxonomy](https://github.com/netresearch/retro-skill/blob/main/references/destination-taxonomy.md) — Where this fits in retro's 6 destinations
- [retro-skill classification-heuristic](https://github.com/netresearch/retro-skill/blob/main/references/classification-heuristic.md) — Friction → checkpoint mapping
