---
name: automated-assessment
description: "Use when working with ANY project compliance assessment, quality enhancement, or test suite improvement. MUST be triggered BEFORE manual quality work begins (e.g., to enhance tests, improve coverage, increase mutation score, or strengthen test suite). Also use for: running quality audits against checkpoint-enabled skills, verifying release readiness, mechanical checks, or LLM-assisted code reviews."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires bash, jq, gh CLI."
metadata:
  author: Netresearch DTT GmbH
  version: "2.18.0"
  repository: https://github.com/netresearch/automated-assessment-skill
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(skills/automated-assessment/scripts/*) Bash(jq:*) Bash(gh:*) Read Glob Grep Agent
---

# Automated Assessment Skill

Systematic compliance assessment against checkpoint-enabled skills.

## Usage

```
/assess                              # All matching skills
/assess skill-repo typo3-testing     # Specific skills only
/assess --force                      # Ignore preconditions
/assess --mechanical-only            # Scripted checks only
/assess --autofix                    # Fix issues automatically
/assess --review                     # Categorize failures
/assess --autoimprove                # Fix + propose improvements
/assess dependency-compatibility     # Dependency compat checks
/assess --pre-push                   # Pre-push validation gate
/assess --check-coverage             # Verify checkpoint coverage
```

### Options

| Option | Effect |
|--------|--------|
| `<skill-names>` | Run checkpoints for named skills only (also accepts domain names like `dependency-compatibility`) |
| `--force` | Skip precondition checks |
| `--mechanical-only` | Skip LLM reviews |
| `--autofix` | Fix failures via responsible skill, re-verify |
| `--review` | Categorize failures, suggest skill improvements |
| `--autoimprove` | Fix + propose checkpoint changes; add `--create-issues` to file issues |
| `--json` | Raw JSON output |
| `--pre-push` | Run pre-push gate (PHPStan, tests, PHP-CS-Fixer, Rector) |
| `--check-coverage` | Verify adequate checkpoint coverage |

### Steps

1. Discover skills, evaluate preconditions
2. Run mechanical checkpoints
3. Group LLM checkpoints by domain, spawn parallel agents
4. Collect results, generate report

## Assessment-First Rule

**CRITICAL**: Run `/assess` BEFORE manual quality work (enhance tests, improve coverage, strengthen suite, upgrade PHPStan, etc.). Assessment generates a structured gap analysis, preventing wasted iterative discovery.

### Workflow
1. `/assess` with relevant skills
2. Review gap report — this becomes the task list
3. Fix in priority order (errors before warnings; use `--autofix` for automated resolution)
4. Re-run `/assess` to verify

## Running one skill's checks without `/assess`

The one-hop form is the slash command with the skill named — `/assess
typo3-extension-upgrade` — and it is the one to reach for from inside another
skill's workflow. It needs no path.

The direct call exists for scripts and for harnesses that have no slash
commands. It takes the sibling path from the loader's base directory, the
checkpoint file, and the project root as the last argument, and every `target:`
resolves against that root — run it from anywhere else and the checks read the
wrong tree. The checkpoint file is the one the skill's front-matter names under
`checkpoints:`, and only where it names none is it `checkpoints.yaml` at the
skill's base directory (the discovery rule in
`references/checkpoint-workflow.md`); passing the root-level file to a skill
that overrides it runs the wrong file or none.

```bash
cd <project-root>
"$SKILL_DIR/../automated-assessment/scripts/run-checkpoints.sh" --force \
  "<the checkpoint file that rule resolves to>" .
```

Measured, and the reason the slash command is named first: the direct form,
placed as a step in a skill body, was in the agent's context in three of three
trials and attempted in none — no trial in twelve bound a variable of any kind,
so a path that has to be assembled is a path that is not taken. The same check
written into the body as a block that runs as pasted was run three of three.
`--force` skips preconditions where the caller already knows they hold; `--json`
for a machine-readable report. Each result line carries the checkpoint id, its
`desc`, and an evidence string; for a `script`-type check that evidence is only
"Script failed" — the runner does not pass the script's own output through — so
the check's `desc` is what tells you where to look. A `blocked` line means the
runner refused the command and the check never ran.

## Checkpoint Types

**Mechanical:** `file_exists`, `file_not_exists`, `contains`, `not_contains`, `regex`, `json_path`, `gh_api`, `command`. **LLM:** `llm_review` (grouped by domain). See `references/checkpoints-schema.md`.

## Domains

`repo-health` `security` `code-quality` `documentation` `git-workflow` `docker` `ddev` `upgrade` `dependency-compatibility` `pre-push`

## Autofix & Review

`--autofix` invokes responsible skill for failures, re-verifies. Statuses: `auto-fixed`, `needs-review`, `unfixable`. `--review`/`--autoimprove` create feedback loops.

## Pre-Push Gate

Only installed tools (`vendor/bin/*`) are checked. Missing tools pass. IDs: PP-01 (PHPStan), PP-02 (PHPUnit), PP-03 (PHP-CS-Fixer), PP-04 (Rector).

## Severity

`error` = blocks release, `warning` = recommendation, `info` = optional.

## Outcomes

`pass` `fail` `skip` `blocked` — counted separately (`total == pass + fail + skip + blocked`). A command whose executable does not exist (`vendor/bin/*` without Composer, a tool not on PATH) is `skip` with evidence `executable not found: <word>`, not a finding.

**Never report a `blocked` checkpoint as a finding.** It means the runner refused the command through its allowlist, so nothing was measured: the defect is in the checkpoint file, not in the assessed project. Report blocked checkpoints as broken checks, run `scripts/validate-checkpoints.sh <file>` against the owning skill, and file them there. A refused precondition is the same thing one level up — the JSON reason says `REFUSED by the runner allowlist`, which is not the same as "this skill does not apply". See `references/checkpoints-schema.md` → "Outcomes".

## References

- `references/checkpoints-schema.md` -- Checkpoint YAML schema and types
- `references/learning-derived-checkpoints.md` -- Retro-to-checkpoint routing contract
- `references/checkpoint-coverage-requirements.md` -- Required coverage categories per skill
- `references/checkpoint-workflow.md` -- Full assessment workflow with autofix loop
- `references/calibration.md` -- Calibration debt, audit cadence, anchor at generation time, ratchet anti-pattern
- `references/dependency-compatibility.md` -- Multi-major-version assessment trigger
- `references/migration-guide.md` -- Adding checkpoints to existing skills
- `references/verification-patterns.md` -- Verification patterns and result schemas
