# Calibration: keeping checkpoints honest over time

Checkpoints are **predictions**, not verdicts. A checkpoint that fires `error` / `warning` / `info` is claiming the project is more or less likely to ship a defect. That claim has to be checked against reality periodically, or it decays into ritual.

This reference covers:

- **Calibration Debt** — when checkpoints stop predicting anything true
- **Calibration Anchor** — what every generated checkpoint must record so the audit has something to test against
- **Anti-pattern: the checkpoint ratchet**

## Calibration Debt

A checkpoint accumulates calibration debt when any of these is true:

- It has never flagged a real defect in N consecutive `/assess` runs (likely redundant — the rule is already enforced upstream, or the failure mode no longer occurs).
- A real defect shipped that the checkpoint should have caught but didn't (false negative — the rule is too narrow).
- The checkpoint repeatedly flags issues the team dismisses as noise (false positive — the rule is miscalibrated or context-blind).

### Periodic calibration

Once per release cycle (or quarterly for low-velocity repos), audit checkpoint output against:

- Bugs reported in production since the last audit (would any checkpoint have caught this?)
- PR review rejections (did a checkpoint that passed correlate with a human reviewer flagging something?)
- Checkpoint dismissal rate (how often is the user overriding a finding?)

Use `--review` to surface candidates; demote to `info`, retire, or tighten the rule based on findings. The point is not to maximize checkpoint count — it is to keep the ones that still predict something true.

## Calibration Anchor

This rule applies at checkpoint *generation* time, via `add-checkpoints`. For each generated checkpoint, record (in a comment or accompanying note) the **defect class it predicts**:

```yaml
- id: TYPO3-CGL-01
  # Predicts: PHP-CS-Fixer violations that block CI green.
  # Calibration: retire if no real CI break in 6 months of /assess runs.
  type: command
  # (other fields omitted)
```

Why: every checkpoint claims to predict something. If you cannot name the defect class in one line, the checkpoint is testing the rule, not the outcome — and will decay into ritual. The periodic calibration above has nothing to anchor against without this.

A checkpoint without a predicted defect class is a candidate for `info` severity at most, never `error`.

## Anti-pattern: the checkpoint ratchet

Adding checkpoints to plug every past defect, never retiring any, until the suite is slow and noisy enough that the team stops reading it. A checkpoint that nobody acts on is worse than no checkpoint — it costs CI time AND trains the team to ignore the report.

## Inspiration

The framing comes from [Spotify Engineering — Better Experiments with LLM Evals: A Funnel, Not a Fork](https://engineering.atspotify.com/2026/5/better-experiments-with-llm-evals-a-funnel-not-a-fork). Their core observation: *"without offline-online signal calibration, our evals are opinions, not evidence."* The same logic transfers to mechanical checkpoints — without periodic outcome correlation, a green checkpoint is an opinion, not evidence.
