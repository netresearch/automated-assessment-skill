# Verification Patterns for Checkpoints

Reusable checkpoint patterns that enforce "evidence before assertion" — i.e. no claim of pass/tested/verified without an artifact backing it.

## Why this exists

Sessions where an agent declares work "tested and verified" without actually running the tests are the single most expensive failure mode. The cost is a full extra PR cycle, plus lost trust. Cheap to prevent: require a checkable artifact — a CI run URL, a test output file, a lint report — and make the checkpoint fail if that artifact is missing.

## Runner compatibility

All patterns below use `type: command`. The current scripted runner (`scripts/run-checkpoints.sh`) skips `type: gh_api` in batch mode, so GitHub-API-backed checks must be written as `command` with an inline `gh api` invocation. `gh api` natively resolves `{owner}` and `{repo}` placeholders when executed inside a git repository, so no additional templating is needed.

Portable shell is required — the same checkpoints run on Linux CI and developer macOS machines. GNU-only flags like `stat -c` and `date -d` are avoided in favor of `find -mtime` and `gh api`-supplied timestamps.

## Pattern 1: CI Run Recency

Assert that the repository's default branch has a recent successful CI run.

```yaml
- id: AA-01
  type: command
  pattern: |
    DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
    AGE=$(gh api "repos/{owner}/{repo}/actions/runs?branch=$DEFAULT&status=success&per_page=1" \
      --jq '.workflow_runs[0].updated_at | fromdateiso8601 | (now - .)')
    [ -n "$AGE" ] && [ "${AGE%.*}" -lt 86400 ]
  severity: error
  desc: "Default branch must have a successful CI run within the last 24 hours"
```

Uses the repo's actual default branch (not hardcoded `main`), and lets `jq` compute the age in seconds.

## Pattern 2: Test-Report Artifact Present

Assert a machine-readable test report exists and was produced in the last day. Uses `find -mtime` for macOS/Linux portability.

```yaml
- id: AA-02
  type: command
  pattern: 'find build/logs/junit.xml -maxdepth 0 -mtime -1 2>/dev/null | grep -q .'
  severity: warning
  desc: "Test report must exist and be <24h old"
```

`find -mtime -1` matches files modified within the last day on both GNU and BSD `find`. The `-maxdepth 0` addresses a single named file without recursion.

## Pattern 3: Release-Workflow Green Before Tag

For skill and plugin repos: the Release workflow run for the most recent tag must have completed successfully. Prevents the "tag before version-bump PR merged" class of bug from reaching users.

```yaml
- id: AA-03
  type: command
  pattern: |
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null) || exit 0  # no tags yet
    STATUS=$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$(git rev-list -n1 "$LATEST_TAG")&per_page=5" \
      --jq '[.workflow_runs[] | select(.name == "Release")] | .[0].conclusion')
    [ "$STATUS" = "success" ]
  severity: error
  desc: "Latest tag's Release workflow must be green"
```

Uses the tag's commit SHA (via `git rev-list -n1`) plus `gh api` with `{owner}/{repo}` placeholders, which `gh` resolves from the git remote. Exits `0` (pass) if the repo has no tags yet.

## Pattern 4: Batch-Operation Dry-Run Artifact

When an operation is scoped to >3 repos, a `plan.md` or `.batch-plan.yml` artifact should exist at the orchestrating repo's root, produced before execution. This is the audit trail for "we knew what we were going to do before we did it."

```yaml
- id: AA-04
  type: file_exists
  target: .batch-plan.yml
  severity: warning
  desc: "Multi-repo batch operations must leave a dry-run plan artifact"
```

This checkpoint is only meaningful on orchestrator repos. Non-orchestrator repos should either not ship it, or guard with a precondition (e.g. a marker file).

## Pattern 5: LLM-Review Rubric — Claim Substantiation

For LLM checkpoints that audit PRs, commits, or release notes, invoke this rubric:

```yaml
- id: AA-05
  domain: repo-health
  rubric: references/verification-patterns.md#claim-substantiation-rubric
  severity: error
  desc: "Claims of tested/verified must cite an artifact"
```

The Markdown anchor `claim-substantiation-rubric` matches the heading below after GitHub-style slugification (lowercase, hyphen-joined).

### Claim Substantiation Rubric

Rubric body (loaded by the LLM checkpoint):

> For any PR comment, commit message, changelog entry, or release-notes passage containing the words "tested", "verified", "working", "confirmed", or "passes":
>
> - **PASS** if the same PR, commit, or release has a linked CI run URL, test-output gist, artifact upload, or pasted command output that supports the claim.
> - **FAIL** if the claim is bare — no artifact, no run URL, no output, no cited SHA.
>
> Record each failure with: location (file:line or PR comment URL), the unsubstantiated claim verbatim, and what would have satisfied the check (e.g. "link to `phpunit` output").

## When to adopt these

- **All skill/plugin repos**: Pattern 3 (guards releases)
- **Skill repos with automated tests**: Patterns 1, 2
- **Repos that drive multi-repo ops**: Pattern 4
- **Every skill with an `llm_reviews` section**: Pattern 5 rubric

## Anti-patterns to avoid in checkpoints

| Anti-pattern | Why it's bad |
|--------------|--------------|
| `contains: "passing"` on README | Trivially satisfied (badge text); no signal |
| `file_exists` on test reports without a freshness bound | Old stale artifacts pass forever |
| Hardcoded `branch=main` in API queries | Breaks on repos with `master`/custom default |
| `type: gh_api` in scripted runs | Runner skips these — use `type: command` with `gh api` inline |
| GNU-only `stat -c %Y` / `date -d` in checkpoints | macOS `stat` is BSD — use `find -mtime` instead |
| LLM prompts that ask "is this okay?" | Non-deterministic; no rubric to anchor |
| Checkpoints that never fail on any real repo | Cosmetic; drop them |
