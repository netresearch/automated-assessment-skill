# Checkpoints YAML Schema

This document defines the schema for `checkpoints.yaml` files used by the automated-assessment skill.

## File Location

Checkpoints files should be placed in skill repositories following the **convention-with-override** pattern:

1. **Convention**: If `checkpoints.yaml` exists in the skill root, it will be auto-discovered
2. **Override**: If `SKILL.md` front matter contains `checkpoints: path/to/file.yaml`, that path is used instead

```
my-skill/
├── SKILL.md              # Skill content
├── checkpoints.yaml      # Auto-discovered by convention
└── references/
    └── llm-rubric.md     # LLM review prompts (optional)
```

## Schema Version

Current schema version: `1`

## Full Schema

```yaml
# checkpoints.yaml
version: 1
skill_id: github-project  # Must match skill name

# Preconditions - evaluated BEFORE any checks; if any fail, skill is skipped
preconditions:
  - type: file_exists
    target: ext_emconf.php
  - type: json_path
    target: composer.json
    pattern: '.type == "typo3-cms-extension"'

# Mechanical checks - run by scripted runner (no LLM needed)
mechanical:
  - id: GH-01                          # Unique ID: SKILL_PREFIX-NUMBER
    type: file_exists                  # Check type (see types below)
    target: README.md                  # File/path to check
    severity: error                    # error | warning | info
    desc: "README.md must exist"       # Human-readable description
    fix_skill: agent-rules             # Optional: skill that can fix this (overrides skill_id)
    provenance: upstream               # Optional: authority class (see Provenance)
    source: https://example.org/spec   # Optional: where the enforced rule canonically lives
    verified: 2026-08-14               # Optional: when source was last checked

  - id: GH-02
    type: contains
    target: README.md
    pattern: "codecov.io"              # Pattern to search for
    severity: warning
    desc: "README should have Codecov badge"

  - id: GH-03
    type: regex
    target: .github/workflows/*.yml    # Supports glob patterns
    pattern: "uses: [^@]+@[a-f0-9]{40}"
    severity: error
    desc: "Actions must be pinned to SHA"

# LLM-based reviews - require agent judgment
llm_reviews:
  - id: GH-15
    domain: repo-health                # Groups related reviews
    rubric: references/llm-rubric.md#badge-order  # Markdown anchor
    severity: warning
    desc: "Verify badge ordering follows standard"

  - id: GH-16
    domain: repo-health
    prompt: |                          # Inline prompt (alternative to rubric)
      Verify the README has these sections:
      - Installation/Setup
      - Usage/Configuration
      - Development
      - License
    severity: info
    desc: "README should have standard structure"
```

## Preconditions

Preconditions are evaluated **before** any mechanical or LLM checks run. They act as guards that determine whether a skill is applicable to the target repository.

### Behavior

- All preconditions must pass (AND logic)
- If **any** precondition fails, the entire skill is **skipped** (this is not an error)
- Preconditions are not reported as findings -- they silently gate the skill

### Fields

Preconditions reuse the same types as mechanical checks but require fewer fields:

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | Check type: `file_exists`, `file_not_exists`, `contains`, `regex`, `json_path`, `command` |
| `target` | Depends | File/path to check (required for file-based types) |
| `pattern` | Depends | Pattern or expression (required for `contains`, `regex`, `json_path`, `command`) |

No `id`, `severity`, or `desc` fields are needed.

### Examples

Skip the skill if the repo is not a TYPO3 extension:

```yaml
preconditions:
  - type: file_exists
    target: ext_emconf.php
  - type: json_path
    target: composer.json
    pattern: '.type == "typo3-cms-extension"'
```

Skip the skill if no Go source files exist:

```yaml
preconditions:
  - type: command
    pattern: "ls *.go 2>/dev/null"
```

Skip the skill if the repo has no CI configuration:

```yaml
preconditions:
  - type: file_exists
    target: .github/workflows
```

## Checkpoint ID Convention

```
{SKILL_PREFIX}-{NUMBER}

GH-01  = github-project checkpoint 1
ER-01  = enterprise-readiness checkpoint 1
TC-01  = typo3-conformance checkpoint 1
TT-01  = typo3-testing checkpoint 1
AG-01  = agents checkpoint 1
```

## Mechanical Check Types

| Type | Description | Required Fields |
|------|-------------|-----------------|
| `file_exists` | File must exist | `target` |
| `file_not_exists` | File must NOT exist | `target` |
| `contains` | File contains literal string | `target`, `pattern` |
| `not_contains` | File does NOT contain string | `target`, `pattern` |
| `regex` | File matches regex pattern | `target`, `pattern` |
| `regex_not` | Pattern is absent from matched file(s) | `target`, `pattern` |
| `json_path` | JSON path exists and is truthy | `target`, `pattern` (jq path) |
| `yaml_path` | YAML path exists | `target`, `pattern` (yq path) |
| `gh_api` | GitHub API check | `endpoint`, `expect_contains` or `json_path` |
| `command` | Run command, check exit code | `pattern` (the command) |

### Type Details

#### `file_exists` / `file_not_exists`

```yaml
- id: GH-01
  type: file_exists
  target: README.md
  severity: error
```

#### `contains` / `not_contains`

Literal string search (not regex):

```yaml
- id: GH-02
  type: contains
  target: README.md
  pattern: "codecov.io"
  severity: warning
```

#### `regex`

Extended regex pattern. Target supports glob patterns:

```yaml
- id: GH-03
  type: regex
  target: .github/workflows/*.yml
  pattern: "uses: [^@]+@[a-f0-9]{40}"
  severity: error
```

#### `regex_not`

Inverse of `regex`. Passes if the pattern is NOT found in any matching file. Target supports glob patterns:

```yaml
- id: ER-25
  type: regex_not
  target: .github/workflows/*.yml
  pattern: "uses: [^@]+@v[0-9]"
  severity: error
  desc: "Actions must not use mutable tag references"
```

#### `json_path`

Uses `jq` to evaluate path. Passes if result is truthy:

```yaml
- id: PM-01
  type: json_path
  target: composer.json
  pattern: '.require["php"]'
  severity: error
```

#### `gh_api`

GitHub API check (requires `gh` CLI authentication):

```yaml
- id: GH-13
  type: gh_api
  endpoint: repos/{owner}/{repo}/topics
  expect_contains: ["typo3", "typo3-extension", "php"]
  severity: error
```

The `{owner}` and `{repo}` placeholders are replaced at runtime.

#### `command`

Run arbitrary command, check exit code:

```yaml
- id: TC-10
  type: command
  pattern: "composer validate --strict"
  severity: error
```

**Two constraints decide whether the checkpoint runs at all.** Both are enforced
by the runner and neither produces a useful failure message on its own, so a
violating checkpoint reads as a gate while never executing. `validate-checkpoints.sh`
checks both at authoring time.

**1. `pattern:` must be a single-line scalar.** The runner parses YAML line by
line, so a block scalar reaches it as the literal `|-`:

```yaml
pattern: |-                                    # WRONG — the runner receives "|-"
  test -z "$(git status --porcelain)"
```

**2. The command must pass the runner's allowlist** (`is_safe_eval_command` in
`lib/command-allowlist.sh`). The base command must be on the whitelist, and the
pattern may contain **no** `;`, `&&`, `||`, backticks, `$(...)`, `..`, or a
`./script` invocation outside `vendor/bin/`. Pipes are allowed.

That rules out loops, command substitution and multi-statement patterns. A check
that needs them belongs in `scripts/`, and the checkpoint **mirrors** a
simplified, allowlist-conform version of it rather than calling it — the runner
cannot invoke repo scripts. Worked examples: `SR-37` in skill-repo mirrors
`check-version-parity.sh`; `GW-17` in git-workflow narrows a five-commit sweep
to HEAD because the sweep needs a loop.

```yaml
pattern: 'test -z "$(git ls-files -- docs/)"'  # WRONG — $( ) is rejected
pattern: "git ls-files -- docs/ | grep -qv ."  # allowed: pipe, no substitution
```

Semicolon-free spellings exist for most one-liners — `sed -n -e '/^$/q' -e p`
does what `sed -n '/^$/q;p'` does.

## LLM Review Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique checkpoint ID |
| `domain` | Yes | Domain group for batching |
| `rubric` | No* | Path to rubric markdown with optional anchor |
| `prompt` | No* | Inline prompt text (alternative to rubric) |
| `severity` | Yes | error, warning, or info |
| `desc` | Yes | Short description for reports |
| `fix_skill` | No | Skill that can fix this checkpoint's failures (overrides `skill_id`) |

*Either `rubric` or `prompt` is required.

**LLM reviews are for what a command cannot decide.** A prompt that opens a line
with a runnable command is a mechanical check written as prose: nothing executes
it, and it cannot regress visibly. Move the deciding part to `mechanical:` and
leave the LLM entry the judgement — "are they all from the same author", "is the
rationale plausible" — that the command does not make.

An entry that deliberately keeps both halves declares its counterpart, and
`validate-skill.sh` (skill-repo) then treats it as intentional rather than
misfiled. Where the command only *gathers context* for a judgement and decides
nothing on its own, say so instead of inventing a mechanical twin:
`# mechanical-counterpart: none (command gathers context; the judgement is the
checkpoint)`.

```yaml
llm_reviews:
  # mechanical-counterpart: GW-17
  - id: GW-21
    domain: git-workflow
    prompt: |
      ...
```

### Domain Groups

Related checkpoints are grouped into domains for efficient LLM batching.

These are the currently supported LLM review domains used for automated assessment. Other domain labels mentioned in SKILL.md or the main README (such as `git-workflow`, `docker`, `ddev`, or `upgrade`) refer to broader skill concepts and are not LLM review domains.

| Domain | Focus Areas |
|--------|-------------|
| `repo-health` | README, badges, branding, AGENTS.md |
| `security` | SLSA, OpenSSF, SBOM, vulnerabilities |
| `code-quality` | PHPStan, tests, PHP patterns |
| `documentation` | RST, rendering, docs.typo3.org |
| `dependency-compatibility` | Multi-version API compat, mock validity, PHPStan ignores |
| `pre-push` | Local CI validation (PHPStan, tests, PHP-CS-Fixer, Rector) |

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| `error` | Must fix before release | Blocks release |
| `warning` | Should fix | Strong recommendation |
| `info` | Nice to have | Optional improvement |

## Provenance (optional fields, required for new normative rules)

A checkpoint turns a sentence into an enforced rule — and an enforced rule
without a named authority hardens into "the standard" even when it never was
one. Three optional fields record who owns the truth a checkpoint enforces:

```yaml
provenance: upstream          # authority class, see table
source: https://docs.example.org/spec/section   # where the rule canonically lives
verified: 2026-08-14          # when the source was last checked (ISO date)
learning_id: retro-20260814-example-slug        # provenance chain to the retro finding
```

`learning_id` links a checkpoint back to the retro finding that produced it
(`retro-YYYYMMDD-<slug>`, minted by retro-skill at proposal time; the same id
appears as a `Learning-Id:` trailer in the materializing commit/PR). It is
what makes a landed learning traceable end to end — and findable for pruning
when the rule is later superseded (retro outcome signal D12).

| `provenance` | Meaning | Requirement |
|---|---|---|
| `upstream` | Derivable from an official external specification/documentation | `source` URL required; re-verify on drift suspicion |
| `org-policy` | Deliberate organisational rule, intentionally at or beyond upstream | Name the policy owner or rationale in `desc`/`source` |
| `regression` | Guards an observed (agent) failure | `source` names the session/issue/PR where the failure occurred |
| `heuristic` | Quality heuristic, not a normative rule | Default to `severity: info`; must not be presented as an external standard |

Runners ignore unknown fields, so these are metadata-only and backward
compatible. **New checkpoints that enforce a normative rule (`upstream` /
`org-policy`) must carry `provenance` and `source`** — see
`learning-derived-checkpoints.md`. Without provenance, a locally-invented
heuristic (e.g. a page-length limit) is indistinguishable from an upstream
standard, and checkpoint + eval + skill text can keep each other green while
the real standard has moved on (authority drift).

## Fix Skill Override

Mechanical checkpoints support an optional `fix_skill` field:

```yaml
fix_skill: agent-rules  # Optional: skill that can fix this checkpoint's failures
```

When present, `fix_skill` overrides the default `skill_id` to `fix_command` mapping for autofix.
This is useful when a checkpoint defined in one skill (e.g., `agents`) is best fixed by a
different skill (e.g., `agent-rules` which generates AGENTS.md). If not specified, the
checkpoint's `fix_skill` defaults to the file's `skill_id`.

## Resolution Logic

The assessment skill uses this logic to find checkpoints:

```python
def find_checkpoints(skill_path):
    skill_md = read_yaml_front_matter(f"{skill_path}/SKILL.md")

    # Override: explicit path in front matter
    if "checkpoints" in skill_md:
        return f"{skill_path}/{skill_md['checkpoints']}"

    # Convention: checkpoints.yaml in skill root
    convention_path = f"{skill_path}/checkpoints.yaml"
    if file_exists(convention_path):
        return convention_path

    # No checkpoints for this skill
    return None
```

## Example: github-project Checkpoints

```yaml
version: 1
skill_id: github-project

preconditions:
  - type: file_exists
    target: .github

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
    type: contains
    target: README.md
    pattern: "codecov.io"
    severity: warning
    desc: "README should have Codecov badge"

  - id: GH-06
    type: regex
    target: README.md
    pattern: "img.shields.io.*license"
    severity: warning
    desc: "README should have license badge"

llm_reviews:
  - id: GH-15
    domain: repo-health
    rubric: references/llm-rubric.md#badge-order
    severity: warning
    desc: "Verify badge ordering follows standard"

  - id: GH-16
    domain: repo-health
    prompt: |
      Check README structure for:
      - Installation section
      - Configuration section
      - Development section
      - License section
    severity: info
    desc: "README should have standard sections"
```

## Validation

Run the validator to check your checkpoints.yaml:

```bash
~/.claude/skills/automated-assessment/scripts/validate-checkpoints.sh checkpoints.yaml
```

The validator checks:
- YAML syntax
- Required fields present
- Valid checkpoint types
- Unique IDs
- Severity values
- `type: command` patterns: single-line scalar, and accepted by the runner's own
  allowlist (sourced from `lib/command-allowlist.sh`, not reimplemented, so
  validation and execution cannot disagree)

The last one is the difference between a checkpoint and the appearance of one:
a pattern the runner rejects never runs, and the assessment report says nothing
about it.

## Checkpoint IDs: next free sequential number, never a temporal prefix

Checkpoint IDs are stable public identifiers — they appear in assessment reports, CI logs, PR descriptions and historical references. Before adding one: `grep -E "^[[:space:]]+- id: <PREFIX>-[0-9]+" checkpoints.yaml`, take the next sequential number (round number for a new thematic group, continued sequence for an extension). Never merge `NEW-`/`TODO-`/`TMP-`/`PLACEHOLDER-` IDs — "new" decays the moment the PR merges while the ID is permanent, and renumbering shipped IDs is follow-up work with breakage risk (happened with `TT-NEW-1..5` on typo3-testing).
