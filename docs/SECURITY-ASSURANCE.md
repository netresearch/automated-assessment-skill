<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — automated-assessment-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it. Reporting a vulnerability: see the [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill content: assessment workflow, schema and rubrics for an AI agent | `skills/*/SKILL.md`, `skills/automated-assessment/references/*.md`, `skills/automated-assessment/assets/llm-rubric-*.md` | Read by the agent as instructions; not executed |
| Skill scaffold | `skills/automated-assessment/assets/skill-template/` | Copied by the user into a new skill |
| Checkpoint runner | `skills/automated-assessment/scripts/run-checkpoints.sh`, `skills/automated-assessment/scripts/lib/command-allowlist.sh` | On the user's machine, in the root of the project under assessment |
| Checkpoint validator | `skills/automated-assessment/scripts/validate-checkpoints.sh` | On a skill author's machine, against a `checkpoints.yaml` |
| Repository checks | `Build/Scripts/check-plugin-version.sh`, `Build/hooks/pre-push`, `scripts/verify-harness.sh`, `tests/*.sh` | On contributors' machines (the pre-push hook, or run by hand); `tests/*.sh` also in this repository's CI |

The skill has no server component, stores no data, and handles no user accounts. The runner needs `bash`, `jq` and, for GitHub checks, an authenticated `gh` CLI; it installs nothing.

## Actors and data flow

1. The user runs `/assess`. The agent discovers the `checkpoints.yaml` of every installed skill (`skills/automated-assessment/references/checkpoint-workflow.md`).
2. For each file, the agent calls `run-checkpoints.sh <checkpoints.yaml> <project-root>`. The runner changes into the project root, evaluates the preconditions and runs each mechanical checkpoint: file tests, `grep`, `jq`, `gh api` calls and allowlisted commands.
3. The runner prints one result per checkpoint (`pass`, `fail`, `skip`, `blocked`), or a JSON report with `--json`.
4. For `llm_review` checkpoints the agent starts review agents that read the project together with the rubrics in `assets/llm-rubric-*.md`.

## Trust boundaries

- **Installed skills and their checkpoint files (trusted).** The trust boundary is installation. A skill already directs the agent through its SKILL.md, and a checkpoint file can run code: the allowlist admits general-purpose interpreters (`awk`, `python3`, `php -r`, `node`), `type: script` runs a multi-line body, and brace targets such as `{a,b}` are expanded with `eval` (`run-checkpoints.sh`, `file_exists`, `contains`, `not_contains`, `regex`, `regex_not`). The header of `lib/command-allowlist.sh` states this and lists the spellings the allowlist knowingly does not stop.
- **Project under assessment (untrusted content).** The runner reads its files as data. A command checkpoint may execute the project's own tooling by design: `./vendor/bin/*`, `composer`, `npm`, `make`, `git`, `phpunit` (the pre-push gate in `SKILL.md` runs `vendor/bin/*`).
- **GitHub.** `gh` runs with the operator's credentials against the repository named by the project's `origin` remote.
- **CI.** Workflows run on GitHub-hosted runners. `ci.yml`, `tests.yml` and `auto-merge-deps.yml` set `permissions: {}` at the top level, `lint.yml` and `harness-verify.yml` set `contents: read`, and `release.yml` grants its job `contents: write`, `id-token: write` and `attestations: write` for the signed release.

## Security requirements

Requirements 1 to 3 bound what a careless checkpoint can do. They are not a defence against a hostile checkpoint author, who is inside the trust boundary (see above and "What a user cannot expect").

1. A one-line command checkpoint that the allowlist refuses is never executed; it is reported as `blocked`.
2. A one-line command runs `gh` (as its first word, after a pipe, or behind a wrapper such as `xargs`) only as a `gh api` request without a method flag or a request body.
3. A one-line command that names a file of the assessed project by a `./` or path-prefixed command word is refused unless the file is under `vendor/bin/`.
4. A checkpoint command runs in a child process and cannot terminate the runner or change its variables.
5. The validator never executes a checkpoint's command.
6. Content fetched from GitHub is read as data and never executed.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| A careless checkpoint deletes files or pipes into a shell (CWE-78) | One-line commands pass an allowlist of command words and are rejected for `rm -r`, `sudo`, `eval`, `exec`, `mkfs`, `dd if=`, recursive `chmod`/`chown`, `curl`/`wget` piped into a shell, a pipe into `sh`/`bash`, `;`, `&&`, `\|\|`, backticks, `$(` and a `$IFS` splice; backslashes are removed before the text checks | `lib/command-allowlist.sh` (`is_safe_eval_command`); `tests/command-allowlist.sh` |
| A checkpoint changes the assessed GitHub repository | `gh` is allowed only as `gh api`, without `-X`/`--method` and without `--input`/`-f`/`-F`/`--field`/`--raw-field`, in every quoting and gluing spelling, wherever it is a command word | `lib/command-allowlist.sh` (`gh_readonly_check`); `tests/command-allowlist.sh` (quoted, escaped, glued and `$'...'` spellings; `gh` after a pipe and behind `xargs`) |
| A checkpoint runs a script shipped by the assessed project (CWE-94) | Every `./X` token and every command word with a path prefix is rejected unless it is under `vendor/bin/`; the command word of each pipe segment is checked with quotes removed, also behind wrappers such as `xargs` and `env` | `lib/command-allowlist.sh`; `tests/command-allowlist.sh` |
| A path leaves the project root through traversal (CWE-22) | A `..` anywhere in a command is rejected | `lib/command-allowlist.sh`; `tests/command-allowlist.sh` (`cat ../secret`, `cat .\./secret`) |
| Globbing in the project directory changes the allowlist verdict | The token scans run with pathname expansion disabled (`set -f`) | `lib/command-allowlist.sh` |
| A command ends the runner with `exit` or `set -e` | One-line commands run in a child `bash <<<`; multi-line scripts run from a `mktemp` file in a child `bash` and the file is removed afterwards | `run-checkpoints.sh` (types `command` and `script`) |
| A refused command is read as a finding about the project | Refusals are counted as `blocked`, never as `fail`, and do not set the exit code; a missing executable is `skip` | `run-checkpoints.sh`; `tests/run-checkpoints-smoke.sh` |
| The validator and the runner disagree about a command | Both source the same allowlist and the same YAML folding function | `lib/command-allowlist.sh`, `validate-checkpoints.sh`; `tests/checkpoint-validation.sh` |
| Crafted YAML instantiates objects in the validator (CWE-502) | The validator parses with `yaml.safe_load` and only screens commands; it does not run them | `validate-checkpoints.sh` |
| The project's `origin` remote injects text into a GitHub API path | Owner and repository are accepted only when they match `[A-Za-z0-9._-]+` | `run-checkpoints.sh` (`resolve_github_owner`) |
| A reusable workflow fetched for `follow_uses` is executed | Fetched content is written to a temp file, searched with `grep` and deleted by an `EXIT` trap; owner, repository and path must match fixed character classes | `run-checkpoints.sh` (`expand_follow_uses`, `cleanup_follow_uses_temps`) |
| A regex in a `contains` check matches more than intended | `contains` and `not_contains` search literally with `grep -F` | `run-checkpoints.sh` |
| A modified release archive is installed | Release archives are listed in `SHA256SUMS.txt`, which is signed with Cosign, and carry SLSA build provenance; the release workflow requires a signed annotated tag | `.github/workflows/release.yml` (reusable `release.yml` of `netresearch/skill-repo-skill`) |
| A defect in a shell script reaches `main` | ShellCheck at severity `style`, the three test suites and the CI checks run on every pull request; ShellCheck, CI and CodeQL are required by the branch protection of `main` | `.github/workflows/lint.yml`, `tests.yml`, `ci.yml` |

## Secure design principles applied

- **Least privilege:** a `gh` command word is limited to read requests (the allowlist is not a sandbox, see below); workflows declare minimal permissions (see trust boundaries).
- **Fail safe:** a command the allowlist cannot classify is refused, not run; a refusal is reported so the checkpoint can be fixed (`blocked`).
- **Single implementation of a rule:** the allowlist exists once and is shared by the runner and the validator (`lib/command-allowlist.sh`).
- **Minimal attack surface:** the runner runs locally, installs nothing and opens no port.

## What a user cannot expect

- **The allowlist is not a sandbox.** A checkpoint author can execute arbitrary code, for example through `awk 'BEGIN{system(...)}'`, `type: script` or a brace `target:`. Install only skills whose checkpoints you would run yourself. `lib/command-allowlist.sh` lists further spellings that pass on purpose: expansion splices other than `$IFS` (`xargs ${x:-rm} -rf dir`), traversal spelled through an expansion, a wrapper that takes its command after a value-bearing flag, and a shell reached through an allowlisted wrapper (`| env sh -c '...'`).
- **Assessing a project may run that project's code.** Checkpoints that call `vendor/bin/*`, `composer`, `npm`, `make` or `git` execute the project's tooling and configuration. Assess an untrusted project only inside a disposable container.
- **LLM reviews read the project as text.** Text in the assessed project can influence the review agents; their verdicts are judgments, not proofs.
- **The runner makes GitHub API requests with your credentials.** They are read-only, but they reach the repository named by the project's `origin` remote and any reusable workflow repository a `follow_uses` checkpoint names.
