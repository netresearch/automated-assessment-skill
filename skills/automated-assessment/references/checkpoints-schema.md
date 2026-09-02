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

**Two things decide whether the checkpoint runs at all.** Both are enforced by
the runner, and a violating checkpoint reads as a gate while never executing.
`validate-checkpoints.sh` checks both at authoring time.

**1. Where the command lives, and which scalar shape it has.** The runner reads
the command from `pattern:`, `command:` or `target:` — `pattern:`/`command:`
first, `target:` as the fallback. All three are equally supported; the estate
uses all three. The *shape* of the scalar decides which screen applies:

| Shape | Reaches the runner as | Screened with |
|---|---|---|
| single-line (plain, `'…'`, `"…"`) | one line | `is_safe_eval_command` (one-liner allowlist) |
| literal block `\|` | the body, newlines kept | `is_safe_script_text` (script screen) |
| folded block `>` | the body folded to **one** line | `is_safe_eval_command` |

A folded scalar is one logical line, exactly as YAML says: `>-` over
`grep -q foo` and `README.md` means `grep -q foo README.md`. Keeping the
newline instead would run `grep -q foo` with no file argument, which blocks on
stdin — so when a body needs to *be* several commands, write `|`, not `>`.

**2. The command must pass the runner's allowlist.** For a one-liner — which a
folded `>` body also is, once folded — that is `is_safe_eval_command` in
`lib/command-allowlist.sh`; a literal `|` body gets the looser script screen
described further down. The base command must be on the whitelist, and the
pattern may contain **no** `;`, `&&`, `||`, backticks, `$(...)`, `..`, or a
`./script` invocation outside `vendor/bin/`. Pipes are allowed, but each pipe
segment's command word obeys the same rule as the first. `$IFS` is rejected
outside single quotes, because splicing it into a blocked token reassembles
that token after the check has run.

The allowlist is a blast-radius limiter, not a sandbox — it exists so a careless
pattern cannot delete a tree or mutate the repo it was asked to inspect. It does
not contain a determined author: `awk`, `php -r` and `python3` are on the
whitelist because real checkpoints need them, and each runs arbitrary code. Do
not treat "it passed the allowlist" as a safety property of a checkpoint, and do
not report a bypass of it as a vulnerability in the assessed project.

That rules out loops, command substitution and multi-statement patterns. A check
that needs them has two legitimate homes, in ascending order of cost:

**`type: script` — an inline multi-line body.** For logic too small to justify a
shipped file, the runner accepts a block-scalar body and executes it with bash:

```yaml
- id: TC-121
  type: script
  severity: error
  desc: "No prohibited execution functions in Classes/"
  command: |
    found=$(find Classes/ -name '*.php' -exec grep -lP '(\bexec\s*\(|\bsystem\s*\()' {} + 2>/dev/null)
    if [ -n "$found" ]; then
      echo "Prohibited function usage in: $found"
      exit 1
    fi
```

The body runs from a temp file in the project root, so relative paths resolve
against the assessed project exactly as a one-liner's do. It is screened by
`is_safe_script_text` (`lib/command-allowlist.sh`) — the `$IFS` splice check and
the dangerous-pattern list (curl/wget piped into sh, `sudo`, `rm -r`, `mkfs`,
recursive chmod/chown, ...) apply unchanged. What deliberately does NOT apply is
the one-liner whitelist and operator ban: `if`, assignments, `$()` and `;` are a
script's grammar, not smuggling, and per-segment whitelist checks are meaningless
across lines. That makes `type: script` strictly more capable than
`type: command` and therefore opt-in by spelling: write it only when a
single-line allowlist-conform pattern genuinely cannot express the check, prefer
mirroring (next paragraph) for anything that grows beyond ~10 lines, and expect
reviewer scrutiny on every script body.

**Mirror into `scripts/`.** A check that needs them belongs in `scripts/`, and
the checkpoint **mirrors** a simplified, allowlist-conform version of it rather
than calling it — the runner cannot invoke repo scripts. Worked examples: `SR-37`
in skill-repo mirrors `check-version-parity.sh`; `GW-17` in git-workflow narrows
a five-commit sweep to HEAD because the sweep needs a loop.

```yaml
pattern: 'test -z "$(git ls-files -- docs/)"'  # WRONG — $( ) is rejected
pattern: "git ls-files -- docs/ | grep -qv ."  # allowed: pipe, no substitution
```

Semicolon-free spellings exist for most one-liners — `sed -n -e '/^$/q' -e p`
does what `sed -n '/^$/q;p'` does.

**Quoting the scalar.** Prefer a plain or single-quoted scalar — the runner
passes both through byte-identically. In a **double-quoted** scalar the runner
decodes exactly the two escapes such a scalar cannot avoid, `\"` → `"` and
`\\` → `\`; every other backslash sequence (`\d`, `\s`, `\$`, ...) passes
through unchanged even where real YAML would decode or reject it. So a regex
backslash in a double-quoted scalar must be written `\\` (standard YAML), and a
pattern that needs literal double quotes is simplest as a plain scalar:

```yaml
pattern: "grep -qP '^go \\d+' go.mod"        # double-quoted: \\ becomes \
pattern: awk '{if ($1 == "x") exit 1}' f     # plain scalar: no escaping at all
```

## Outcomes: pass, fail, skip, blocked

A checkpoint run reports one of four outcomes per checkpoint, and the summary
counts them separately (`total == pass + fail + skip + blocked`):

| Status | Meaning | Is it a finding about the project? |
|---|---|---|
| `pass` | the check ran and the project satisfied it | — |
| `fail` | the check ran and the project did not satisfy it | **yes** |
| `skip` | the check does not apply here (no files match the glob, `gh` unavailable, ...) | no |
| `blocked` | the runner **refused the command**, so it never ran | no — a defect in the *checkpoint* |

`blocked` exists because reporting a refusal as a failure invents findings. In
one estate-wide audit 68 checkpoints were refused by the allowlist and counted
as failures; 39 of those passed once the command was run by hand. A refused
command produces no evidence in either direction, and the fix belongs to the
checkpoint file, not to the assessed project.

Consequences to rely on:

- `blocked` never sets the runner's exit code — only `fail` does. A release
  gate reading the exit code cannot be tripped by a broken checkpoint.
- `fail` and `status: "fail"` keep their meaning, minus the refusals that were
  never evidence; `blocked` appears only where the runner previously emitted a
  false `fail`. A consumer that knows only pass/fail/skip therefore reads a
  *smaller, more truthful* `fail` set, and can treat an unknown `blocked` the
  way it treats `skip`.
- A refused **precondition** command is reported in the skipped-skill JSON with
  a reason that says `REFUSED by the runner allowlist`, not "precondition
  failed" — the skill was not measured, it was not found inapplicable.

## Three defect classes that make a checkpoint misreport

These are the three ways a checkpoint reports something that is not true. All
three were found in the shipped estate (24 + 10 + 7 instances across the 21
checkpoint files), and none of them looks wrong in the YAML.

### Class 1 — vendor leakage

**Failing shape:** a `find`, a glob target or a `file_exists` target that walks
the tree with no exclusion for dependency directories. This one shipped as
typo3-ckeditor5's precondition:

```yaml
preconditions:
  - type: command
    pattern: "find . -path '*/JavaScript/Ckeditor*' -o -path '*/JavaScript/ckeditor*' -o -path '*/RTE/*.yaml' -o -path '*/RTE/*.yml' | head -1 | grep -q ."
```

**Why it misreports silently:** the runner's auto-exclude list
(`DEFAULT_EXCLUDE_DIRS`: `vendor`, `node_modules`, `.Build`, `var/cache`, ...)
applies **only to glob targets of the content check types** (`contains`,
`not_contains`, `regex`, `regex_not`). It does **not** apply to `file_exists`
globs, **not** to `command`/`script` bodies, and **not** to preconditions. An
author who has read that the runner auto-excludes dependencies reasonably
assumes it covers these too.

Run in `t3x-nr-temporal-cache` — a caching extension with no RTE code and no
JavaScript at all — that precondition exits 0, and the single path it matches is

```
./.Build/vendor/typo3/cms-core/Configuration/RTE/SysNews.yaml
```

a file shipped by TYPO3 core, inside the ignored build directory. On that
evidence the skill declared itself applicable and all 14 typo3-ckeditor5
checkpoints ran against the extension; every one of their failures was reported
as a finding about it.

**Correct shape** — exclude explicitly, in the check itself. The same
precondition with `-prune` exits 1 on that extension, which is the right
answer:

```yaml
    pattern: "find . '(' -name vendor -o -name node_modules -o -name .Build -o -name .git ')' -prune -o '(' -path '*/JavaScript/Ckeditor*' -o -path '*/RTE/*.yaml' ')' -print | grep -q ."
```

For a file-based check, anchor the target instead of reaching for `**/`:

```yaml
    target: "Configuration/RTE/*.yaml"        # anchored, not "**/…"
```

(and note that a `file_exists` **precondition** is evaluated with a plain
`[[ -f ]]`/`[[ -d ]]` test — no glob, no brace expansion — so a pattern there
matches nothing and skips the skill everywhere. The validator errors on it.)

The rule is: **if the check is not a content check with a glob target, the
exclusion is your job.** `validate-checkpoints.sh` warns on a bare `find .`
with no `-prune`/`vendor`/`node_modules`/`.Build` anywhere in the command.

### Class 2 — skill-relative script path

**Failing shape:** a checkpoint invoking a script the skill ships.

```yaml
  - id: TD-30
    type: command
    pattern: "bash scripts/check-guides-xml-schema.sh"   # WRONG — twice over
```

**Why it can never work:** a checkpoint runs with the working directory set to
the **repository under assessment**, where the skill's `scripts/` does not
exist; and the runner's allowlist rejects any base command with a path prefix
except `vendor/bin/*`, so `bash scripts/...` is refused before the path is even
tried. Ten instances shipped in typo3-docs. Every one reported a failure that
said nothing about the project.

**Correct shape:** inline the logic as one self-contained allowlisted command —
`php -r '...'` is ideal for anything non-trivial — and keep the shipped
`scripts/*.sh` as the human-facing entry point. TD-05 in typo3-docs carries a
comment stating exactly this trap, next to its inlined replacement:

```yaml
  - id: TD-05
    type: command
    # Inlined rather than calling scripts/check-guides-xml-schema.sh, because a
    # checkpoint runs from the repository root and the skill's own scripts are
    # not there.
    pattern: |
      php -r '$d = new DOMDocument(); ...'
```

Note the `|`: a body with `;` in it is a script body, not a one-liner (the
one-liner allowlist rejects `;` wherever it appears, quoted or not).

### Class 3 — pipe-into-head exit trap

**Failing shape:**

```yaml
    pattern: 'grep -rl "@todo" Classes/ | head -1 && echo "found" && exit 1 || exit 0'
```

**Why it always reports failure:** `head` exits **0 on empty input**. The exit
status of the pipeline is `head`'s, not `grep`'s, so the `&&` branch fires
whether or not anything matched, and the checkpoint reports a finding against
every project it is ever run on. Two findings from this shape were reported to
a user as real. It is doubly broken: the runner also rejects `&&` and `||`
outright, so as written the checkpoint is `blocked` and never runs at all —
which is how it survives review, because nobody sees it produce a wrong answer.

**Correct shape:** let the exit status come from the match itself.

```yaml
    pattern: 'grep -rlq "@todo" Classes/'          # inverted below, or use regex_not
```

```yaml
  - id: XX-01
    type: regex_not                                # better: no command at all
    target: Classes/**/*.php
    pattern: "@todo"
```

For anything that genuinely needs several steps, use a literal block body and
let the script's own `exit` decide:

```yaml
    command: |
      hits=$(grep -rl "@todo" Classes/ 2>/dev/null)
      test -z "$hits"
```

`validate-checkpoints.sh` warns when a command pipes into `head` and also
contains `&&`/`||`.

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
${CLAUDE_SKILL_DIR}/scripts/validate-checkpoints.sh checkpoints.yaml
```

The validator checks:
- YAML syntax
- Required fields present
- Valid checkpoint types
- Unique IDs
- Severity values
- `type: command` / `type: script`: that a command exists under one of the three
  keys the runner reads, and that it is accepted by the runner's own allowlist
  — sourced from `lib/command-allowlist.sh`, not reimplemented, so validation
  and execution cannot disagree. Block-scalar bodies are collected and screened
  too, folded ones through the same fold the runner applies
- Preconditions: that the type is one the runner's precondition evaluator
  actually implements (a `file_not_exists` precondition, for instance, is never
  satisfied and silently skips the skill against every project), and that a
  precondition command is a single-line scalar the allowlist accepts
- Warnings for defect classes 1 and 3 above, which no allowlist can see

The last one is the difference between a checkpoint and the appearance of one:
a pattern the runner rejects never runs, and the assessment report says nothing
about it.

## Checkpoint IDs: next free sequential number, never a temporal prefix

Checkpoint IDs are stable public identifiers — they appear in assessment reports, CI logs, PR descriptions and historical references. Before adding one: `grep -E "^[[:space:]]+- id: <PREFIX>-[0-9]+" checkpoints.yaml`, take the next sequential number (round number for a new thematic group, continued sequence for an extension). Never merge `NEW-`/`TODO-`/`TMP-`/`PLACEHOLDER-` IDs — "new" decays the moment the PR merges while the ID is permanent, and renumbering shipped IDs is follow-up work with breakage risk (happened with `TT-NEW-1..5` on typo3-testing).
