# Checkpoint Workflow

Detailed assessment workflow, checkpoint format, agent prompts, and validation rules.

## Assessment Workflow Steps

### Step 1: Discover Checkpoints

```bash
# Find all skills with checkpoints
for skill_dir in ~/.claude/plugins/cache/*/skills/*/; do
  skill_md="$skill_dir/SKILL.md"
  checkpoints_yaml="$skill_dir/checkpoints.yaml"

  # Check override in front matter
  override=$(grep -E "^checkpoints:" "$skill_md" 2>/dev/null | cut -d: -f2 | tr -d ' ')

  if [[ -n "$override" ]]; then
    checkpoint_file="$skill_dir/$override"
  elif [[ -f "$checkpoints_yaml" ]]; then
    checkpoint_file="$checkpoints_yaml"
  else
    continue  # No checkpoints for this skill
  fi

  echo "Found: $checkpoint_file"
done
```

#### Checkpoint Discovery (Convention-with-Override)

For each skill, checkpoints are discovered using this logic:

```
1. Parse SKILL.md front matter
2. If `checkpoints:` key exists -> use that explicit path (override)
3. Else if checkpoints.yaml exists in skill root -> use it (convention)
4. Else -> no checkpoints, skip this skill
```

##### Skill Structure with Checkpoints

```
my-skill/
├── SKILL.md              # Skill content, optional checkpoints: key
├── checkpoints.yaml      # Auto-discovered by convention
└── references/
    └── llm-rubric.md     # LLM review prompts (optional)
```

##### Why Convention-with-Override?

| Pattern | Pros | Cons |
|---------|------|------|
| **Convention** | Zero config, predictable location | Less flexible |
| **Override** | Full control, non-standard paths | Requires config |
| **Both** | Best of both worlds | Slightly more complex discovery |

### Step 2: Evaluate Preconditions

For each discovered skill, evaluate its `preconditions:` block. All preconditions must pass (AND logic). If any precondition fails, the entire skill is silently skipped -- this is not an error.

```bash
# For each discovered checkpoint file:
# 1. Parse the preconditions block
# 2. Run each precondition (same types as mechanical checks)
# 3. If ANY fails -> skip this skill entirely
# 4. If ALL pass -> proceed to mechanical checks
```

This prevents irrelevant skills from producing false negatives (e.g., TYPO3 checks on a Go project).

### Step 3: Run Scripted Checks (Tier 1)

For each mechanical checkpoint (in skills that passed preconditions):

```bash
scripts/run-checkpoints.sh <checkpoint-file.yaml> <project-root>
```

This runs all `file_exists`, `contains`, `regex`, etc. checks without any LLM involvement.

### Step 4: Run Domain Agents (Tier 2)

Group `llm_review` checkpoints by domain, spawn one agent per domain:

```
Agent: repo-health
Checkpoints: GH-15, GH-16, NB-01, AG-01
Prompt: "You are auditing repo health. Verify these checkpoints..."
Output: JSON with pass/fail per checkpoint
```

### Step 5: Aggregate Results

Collect all results into compliance report:

```json
{
  "project": "netresearch/contexts",
  "timestamp": "2026-01-30T19:00:00Z",
  "overall_status": "FAIL",
  "summary": {
    "total": 45,
    "pass": 38,
    "fail": 5,
    "skip": 2
  },
  "checkpoints": [
    {"id": "GH-01", "skill": "github-project", "status": "pass", "evidence": "README.md exists"},
    {"id": "GH-03", "skill": "github-project", "status": "fail", "evidence": "Missing codecov badge"}
  ]
}
```

## Checkpoints YAML Format

Create `checkpoints.yaml` in your skill root:

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
    type: contains
    target: README.md
    pattern: "codecov.io"
    severity: warning
    desc: "README should have Codecov badge"

llm_reviews:
  - id: GH-15
    domain: repo-health
    rubric: references/llm-rubric.md#badge-order
    severity: warning
    desc: "Verify badge ordering follows standard"

  - id: GH-16
    domain: repo-health
    prompt: |
      Check README structure for standard sections:
      - Installation/Setup
      - Configuration
      - Development
      - License
    severity: info
    desc: "README should have standard sections"
```

For full schema documentation, see `references/checkpoints-schema.md`.

## Agent Prompt Template

Each domain agent receives this prompt:

```markdown
You are an automated compliance auditor for projects.

## Your Task
Verify the project against ONLY the checkpoints listed below.
You must NOT fix issues - only report compliance status.

## Output Format
Return ONLY a JSON object with this exact structure:
{
  "domain": "repo-health",
  "checkpoints": [
    {
      "id": "GH-15",
      "status": "pass" | "fail" | "skip",
      "evidence": "Quote the specific line/file or explain why it fails/passes"
    }
  ]
}

## Checkpoints to Verify
[CHECKPOINTS INJECTED HERE]

## Rules
- Every checkpoint MUST have a status (no nulls)
- Evidence MUST be specific (line numbers, quotes)
- "skip" only if checkpoint doesn't apply to this project type
- Be strict - when in doubt, mark as "fail"
```

## Validation Rules

The assessment is NOT complete until:

- [ ] All skills were scanned for checkpoints
- [ ] All scripted checks returned exit code
- [ ] All domain agents returned valid JSON
- [ ] All checkpoints have non-null status
- [ ] Evidence field is non-empty for all fail/pass

If ANY validation fails, retry that component.

## Implementation Notes

### Why Domain Batching?

- **Not 20 agents** (one per skill) - too expensive, rate limits
- **Not 1 agent** (all skills) - context overload, satisficing
- **3-4 domain agents** - balanced context, related checks grouped

### Why Scripted Checks First?

- **Zero LLM cost** for mechanical checks
- **100% accuracy** (no hallucination)
- **Faster** than LLM
- **Catches 60-70%** of issues without any LLM calls

### Checkpoint ID Convention

```
{SKILL_PREFIX}-{NUMBER}

GH-01  = github-project checkpoint 1
ER-01  = enterprise-readiness checkpoint 1
TC-01  = typo3-conformance checkpoint 1
```

## Migration Path

1. **Phase 1**: Add checkpoints to pilot skills (github-project, enterprise-readiness, agents)
2. **Phase 2**: Test assessment on contexts project
3. **Phase 3**: Add checkpoints to remaining skills
4. **Phase 4**: Integrate with CI (automated assessment on PR)

## Review & Auto-improve Workflow

The `--review` and `--autoimprove` flags close the feedback loop from assessment results back into skill definitions. Instead of just reporting failures, they analyze *why* checkpoints fail and propose changes to the skills themselves.

### Feedback Loop

```
assessment → failures → categorization → improvement proposals → skill updates
```

1. Run normal assessment (mechanical + LLM checks)
2. Categorize each failure by root cause
3. Generate improvement proposals
4. Optionally create GitHub issues in skill repos

### `--review` Output

`--review` produces a categorized failure report. Each failure is classified:

| Category | Meaning | Example |
|----------|---------|---------|
| `fixable` | A skill's slash command can fix this | Missing badge → `/github-project` adds it |
| `skill-gap` | Skill doesn't cover this pattern | New TYPO3 14 API not in typo3-conformance |
| `checkpoint-issue` | Checkpoint is miscalibrated | Severity too high, precondition too broad |

Output format:

```json
{
  "review": {
    "fixable": [
      {"id": "GH-03", "skill": "github-project", "fix_command": "/github-project"}
    ],
    "skill_gaps": [
      {"id": "TC-12", "skill": "typo3-conformance", "gap": "No checkpoint for PSR-14 event usage"}
    ],
    "checkpoint_issues": [
      {"id": "ER-05", "skill": "enterprise-readiness", "issue": "severity:error but only applies to public packages"}
    ]
  }
}
```

### `--autoimprove` Workflow

`--autoimprove` extends `--review` with concrete fix proposals:

1. **Autofix phase**: Run `--autofix` for all `fixable` failures
2. **Analysis phase**: For remaining failures (`skill-gap` and `checkpoint-issue`), analyze root cause
3. **Proposal phase**: Generate structured improvement proposals
4. **Issue phase** (with `--create-issues`): File GitHub issues in the relevant skill repos

### Improvement Proposal Format

Each proposal targets a specific file in a skill repo:

```json
{
  "improvements": [
    {
      "skill": "typo3-conformance",
      "category": "skill-gap",
      "checkpoint_id": "TC-12",
      "proposed_action": "add_checkpoint",
      "reason": "No checkpoint verifies PSR-14 event listener registration",
      "target_file": "checkpoints.yaml",
      "suggestion": {
        "id": "TC-15",
        "type": "contains",
        "target": "Configuration/Services.yaml",
        "pattern": "listener",
        "severity": "warning",
        "desc": "Extensions should register event listeners via Services.yaml"
      }
    },
    {
      "skill": "enterprise-readiness",
      "category": "checkpoint-issue",
      "checkpoint_id": "ER-05",
      "proposed_action": "modify_checkpoint",
      "reason": "Severity error is too strict for private extensions",
      "target_file": "checkpoints.yaml",
      "suggestion": {
        "change": "severity",
        "from": "error",
        "to": "warning"
      }
    },
    {
      "skill": "github-project",
      "category": "checkpoint-issue",
      "checkpoint_id": "GH-08",
      "proposed_action": "add_precondition",
      "reason": "Check fails on non-TYPO3 projects that don't use Codecov",
      "target_file": "checkpoints.yaml",
      "suggestion": {
        "add_precondition": {
          "type": "file_exists",
          "target": "composer.json"
        }
      }
    }
  ]
}
```

### Proposed Actions

| Action | What It Changes | When Used |
|--------|----------------|-----------|
| `add_checkpoint` | New entry in `checkpoints.yaml` | Skill gap — missing coverage |
| `modify_checkpoint` | Change severity, desc, or target | Checkpoint miscalibrated |
| `add_precondition` | New precondition to narrow scope | Checkpoint fires on wrong project types |
| `update_skill` | Propose SKILL.md content change | Skill guidance incomplete |

### `--create-issues` Integration

When `--autoimprove --create-issues` is used, each improvement proposal becomes a GitHub issue in the target skill's repository:

- **Title**: `[assessment] {proposed_action}: {checkpoint_id} — {short reason}`
- **Body**: Full proposal JSON, evidence from the assessment, and suggested fix
- **Labels**: `assessment`, `improvement`
- **Repo**: Determined from skill metadata (e.g., `netresearch/typo3-conformance-skill`)

Issues are only created for `skill-gap` and `checkpoint-issue` categories — `fixable` items are handled by `--autofix`.

## Troubleshooting

### "Checkpoint X has null status"
Agent failed to evaluate that checkpoint. Re-run with verbose mode.

### "Domain agent returned invalid JSON"
Prompt may need adjustment. Check agent output for parsing errors.

### "Scripted check failed unexpectedly"
Verify target path is correct. Check if file exists.

### "No checkpoints found for skill X"
Skill doesn't have checkpoints.yaml and no override in front matter. Add checkpoints.yaml following the schema in [`references/checkpoints-schema.md`](checkpoints-schema.md).
