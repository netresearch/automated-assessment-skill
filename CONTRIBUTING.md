<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Contributing

Contributions follow the [contribution guide of the `netresearch` organisation](https://github.com/netresearch/.github/blob/main/CONTRIBUTING.md): signed commits with a DCO sign-off, Conventional Commit messages, and pull requests against `main`.

## Checks on pull requests

This repository does not call the organisation's shared security workflows. The checks that run on every pull request to `main`, and the ones that do not run here, are listed in the README section [Governance and policies](README.md#governance-and-policies).

Run the tests locally before opening a pull request:

```bash
for t in tests/*.sh; do bash "$t" || exit 1; done
```
