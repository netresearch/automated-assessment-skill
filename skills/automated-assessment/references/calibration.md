<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

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

### Finding feedback, including clean reviews

Keep a ledger keyed by stable finding ID and the reviewed revision. Record the
checkpoint/rule version, affected file and line, trigger, impact, evidence and
validation result. Separate impact severity from confidence in the evidence;
an uncalibrated score or agreement between agents does not prove a defect.

Close each candidate with a reason: `confirmed`, `false-positive`, `intentional`
(the behavior is desired), or `deferred` (a real issue accepted for later work).
An unexplained dismissal is not a false positive, and a deferred defect is not a
successful fix. Preserve old/new revision links when a repair resolves a finding.
Count a defect discovered after a clean review as missed only when evidence
shows it was present in the reviewed revision and within that review's scope.
Retain that revision evidence and name the check that should have found it.
Exclude defects introduced by later changes; if earlier presence cannot be
established, leave the calibration attribution unverified rather than counting
a false negative. Do not blame a PR for an older defect; repository-wide
assessments can still report that existing defect.

Use confirmed historical failures and independently verified clean examples in
regression evaluations. Measure known-defect recall, false positives and harmful
repair suggestions on clean examples together with rounds, elapsed time and
tool/token usage. A larger comment count is not a quality improvement. Keep
environment errors, denied access and timeouts visible outside valid negative
examples so they cannot inflate a clean-review rate.

Recheck the baseline after a model, prompt, tool or harness change. Compare old
and new conditions on the same isolated fixtures; reserve separate final test
cases from those used to tune the rule. Remove one mechanism at a time when
testing whether it still contributes. Retire a rule that adds cost or interrupts
authorized work without a demonstrated benefit; a team preference can remain
useful without being claimed as an increase in model capability.

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

Anthropic's [code-review engineering account](https://claude.dev/blog/solving-code-review-at-anthropic/)
describes separate finding validation, clean-change probes and convergence
controls. Its [agent evaluation guide](https://www.anthropic.com/research/demystifying-evals-for-ai-agents)
distinguishes actual outcomes from a transcript's claims. These support the
feedback contract above; their reported improvements are not measurements of
this skill.

The framing comes from [Spotify Engineering — Better Experiments with LLM Evals: A Funnel, Not a Fork](https://engineering.atspotify.com/2026/5/better-experiments-with-llm-evals-a-funnel-not-a-fork). Their core observation: *"without offline-online signal calibration, our evals are opinions, not evidence."* The same logic transfers to mechanical checkpoints — without periodic outcome correlation, a green checkpoint is an opinion, not evidence.
