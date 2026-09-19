# Capability selection: declining beats substituting

The rule in `SKILL.md` — name no skill rather than the nearest one — is not a
preference. It is what an ablation measured, and the measurement is the only
reason to trust it over the instinct to be helpful.

## The measurement

`netresearch/agent-system-evals`, case `OFR-TYPO3-EXT-001` (review a TYPO3
extension), `claude-haiku-4-5-20251001`, three trials per arm:

| arm | what the agent invoked |
| ----- | ------------------------ |
| `nr` (full fleet) | `typo3-conformance`, 3 of 3 |
| `nr` minus `typo3-conformance` | `automated-assessment` then `typo3-extension-upgrade`; `automated-assessment` then `security-audit`; nothing |
| `nr` minus `automated-assessment` | `typo3-conformance`, 3 of 3 |

Two readings, and the second is the one this page exists for:

- **With the right domain skill present, this skill contributes nothing
  measurable.** Removing it changed no dimension count, and the cost was
  identical to the cent. The agent selects the domain skill from the request
  alone.
- **With the right domain skill absent, this skill is what the agent reaches
  for — and what comes back is an upgrade skill or a security skill for a review
  task.** `capability_selection` fell from 12 criteria met to 3, and that arm
  scored **below the arm with nothing at all**.

So the substitution is not a partial answer that beats silence. It is worse than
silence, because a named skill reads as a decision somebody made.

## What declining looks like

State what the request needs, state that nothing offered covers it, and stop.
Do not run an adjacent skill's checkpoints "for what they can tell us": a
checkpoint file scopes itself to its own domain, so its passes say nothing about
the domain that was actually asked about, and its failures are noise the reader
has to spend a round dismissing.

> No skill here covers reviewing a TYPO3 extension for conformance. The closest
> available are `typo3-extension-upgrade` (version migrations) and
> `security-audit` (OWASP review); neither answers this. What would fit is a
> TYPO3 conformance skill — it is not in this fleet.

Naming the gap is useful output. It routes the next person to the missing
capability rather than to a report that looks like an answer.

## What this page does not settle

The other half of the finding is open: `OFR-TYPO3-RELEASE-001` asks to prepare a
release, this skill's description names *verifying release readiness* in the
words the request uses, and it was invoked in none of four trials. Description
coverage is necessary and not sufficient, and what closes that gap is not known.
It is tracked in
[automated-assessment-skill#79](https://github.com/netresearch/automated-assessment-skill/issues/79),
and both halves are measurable against six-trial series that already exist.

Evidence: `tasks/open/typo3-extension-review/RESULTS.md` and
`tasks/open/typo3-release-prep/RESULTS.md` in `netresearch/agent-system-evals`.
