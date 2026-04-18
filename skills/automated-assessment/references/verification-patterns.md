# Verification Patterns for Checkpoints

Reusable checkpoint patterns that enforce "evidence before assertion" — i.e. no claim of pass/tested/verified without an artifact backing it.

## Why this exists

Sessions where an agent declares work "tested and verified" without actually running the tests are the single most expensive failure mode. The cost is a full extra PR cycle, plus lost trust. Cheap to prevent: require a checkable artifact — a CI run URL, a test output file, a lint report — and make the checkpoint fail if that artifact is missing.

## Pattern 1: CI Run Recency

Assert that the default branch has a recent successful CI run. If the last run is old or failed, the repo cannot be declared "verified."

```yaml
- id: AA-01
  type: gh_api
  endpoint: repos/{owner}/{repo}/actions/runs?branch=main&status=success&per_page=1
  json_path: '.workflow_runs[0] | (now - (.updated_at | fromdateiso8601)) < 86400'
  severity: error
  desc: "Default branch must have a successful CI run within the last 24 hours"
```

## Pattern 2: Test-Report Artifact Present

For languages with machine-readable test reports (JUnit XML, coverage.xml, etc.), assert the artifact exists and is recent.

```yaml
- id: AA-02
  type: command
  pattern: 'test -f build/logs/junit.xml && [ $(stat -c %Y build/logs/junit.xml) -gt $(date -d "-1 day" +%s) ]'
  severity: warning
  desc: "Test report must exist and be <24h old"
```

## Pattern 3: No Untested Commits on Default Branch

Every commit on the default branch since the last release tag should be covered by at least one test run. Proxy: compare commit SHAs with GitHub Actions run SHAs.

```yaml
- id: AA-03
  type: command
  pattern: |
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    RANGE="${LAST_TAG:+${LAST_TAG}..}HEAD"
    UNTESTED=0
    for sha in $(git log --format=%H $RANGE); do
      RUN=$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$sha&status=success&per_page=1" --jq '.total_count')
      [ "$RUN" = "0" ] && UNTESTED=$((UNTESTED+1))
    done
    [ $UNTESTED -eq 0 ]
  severity: warning
  desc: "All commits on default branch since last tag must have passing CI"
```

## Pattern 4: Batch-Operation Dry-Run Presence

When an operation is scoped to >3 repos, a `plan.md` or `.batch-plan.yml` artifact should exist at the root of the orchestrating repo, produced before execution. This is the audit trail for "we knew what we were going to do before we did it."

```yaml
- id: AA-04
  type: file_exists
  target: .batch-plan.yml
  severity: warning
  desc: "Multi-repo batch operations must leave a dry-run plan artifact"
```

Skills that drive batch ops (github-project, skill-repo) can reference this check via `fix_skill: github-project`.

## Pattern 5: LLM-Review Rubric — Claim Substantiation

For LLM checkpoints that audit PRs or commits, include this rubric fragment:

```markdown
### Claim Substantiation (severity: error)

For any PR comment, commit message, or changelog entry containing the words
"tested", "verified", "working", "confirmed", or "passes":

- PASS if the same PR or commit has a linked CI run, test-output gist, or
  quoted command output proving the claim
- FAIL if the claim is bare — no artifact, no run URL, no output

Record each failure with: location (file:line or PR comment URL), the
unsubstantiated claim, and what would have satisfied the check.
```

Invoke from a checkpoint:

```yaml
- id: AA-10
  domain: repo-health
  rubric: references/verification-patterns.md#claim-substantiation
  severity: error
  desc: "Claims of tested/verified must cite an artifact"
```

## Pattern 6: Release-Workflow Green Before Tag

For skill-repo releases: the Release workflow for the most recent tag must have completed successfully. Prevents the "30 failed plugin releases" class of bug from reaching users.

```yaml
- id: AA-20
  type: command
  pattern: |
    LATEST_TAG=$(git describe --tags --abbrev=0)
    STATUS=$(gh run list --workflow Release --branch "$LATEST_TAG" \
      --json conclusion --jq '.[0].conclusion')
    [ "$STATUS" = "success" ]
  severity: error
  desc: "Latest tag's Release workflow must be green"
```

## When to adopt these

- **All skill repos**: Patterns 1, 6 (they guard releases)
- **Skill repos with tests**: Pattern 2
- **Skills that drive multi-repo ops**: Pattern 4
- **Every skill with an `llm_reviews` section**: Pattern 5 rubric

## Anti-patterns to avoid in checkpoints

| Anti-pattern | Why it's bad |
|--------------|--------------|
| `contains: "passing"` on README | Trivially satisfied; no signal |
| Time-less `file_exists` on test reports | Old stale artifacts pass forever |
| LLM prompts that ask "is this okay?" | Non-deterministic; no rubric to anchor |
| Checkpoints that never fail on any real repo | Cosmetic; drop them |
