# Checkpoint Coverage Requirements

This document defines the minimum checkpoint coverage requirements for skills that enforce code quality, testing, or dependency management standards.

## Purpose

When a skill SHOULD have caught an issue but did not, it usually means the skill's `checkpoints.yaml` is missing coverage for that failure class. This reference defines what categories of checkpoints each skill domain must include.

## Required Coverage Categories

### API Compatibility

Skills dealing with dependency management or version upgrades must include checkpoints that verify:

| Checkpoint Focus | What to Verify | Example |
|-----------------|----------------|---------|
| Method existence | Called methods exist on all supported versions of interfaces/classes | `encode()` vs `toWebp()` across intervention/image versions |
| Constructor signatures | Constructor parameters match across supported versions | `new ImageManager(array)` vs `new ImageManager(Driver)` |
| Return type changes | Return types are compatible across versions | `string` vs `EncodedImage` |
| Removed/renamed classes | Class references resolve across all versions | `Intervention\Image\Image` vs `Intervention\Image\Interfaces\ImageInterface` |

**Checkpoint template:**

```yaml
- id: XX-API-01
  domain: dependency-compatibility
  prompt: |
    Verify that all method calls on dependency interfaces/classes exist
    across ALL major versions declared in composer.json constraints.
    Check for:
    1. Methods called that don't exist in some versions
    2. Constructor signatures that changed between versions
    3. Return types that changed between versions
    4. Classes/interfaces that were renamed or removed
  severity: error
  desc: "API calls must be compatible with all declared dependency versions"
```

### Test Mock Validity

Skills dealing with testing must include checkpoints that verify:

| Checkpoint Focus | What to Verify | Example |
|-----------------|----------------|---------|
| Mocked methods exist | Methods passed to `->method()` exist on the mocked interface | `->method('encode')` on `ImageInterface` |
| Mock return types match | `->willReturn()` values match current method signatures | Returning `string` when method now returns `EncodedImage` |
| Mock constructor args | `getMockBuilder()` class still accepts those constructor args | Mocking a class whose constructor changed |
| Prophecy compatibility | `->prophesize()` targets valid interfaces | Interface may have been split or merged |

**Checkpoint template:**

```yaml
- id: XX-MOCK-01
  domain: code-quality
  prompt: |
    Verify that all test mocks and stubs reference methods that actually
    exist on the interfaces/classes being mocked. Check:
    1. ->method('X') calls reference methods that exist on the mock target
    2. ->willReturn() values match the actual method return types
    3. Mock constructors match the real class constructors
    Report any mocks that reference non-existent methods.
  severity: error
  desc: "Test mocks must reference methods that exist on mocked interfaces"
```

### PHPStan Ignore Tag Validity

Skills dealing with static analysis must include checkpoints that verify:

| Checkpoint Focus | What to Verify | Example |
|-----------------|----------------|---------|
| Tags suppress real issues | Each `@phpstan-ignore` tag has a corresponding actual error | Tag suppressing non-existent error |
| Tags work across versions | Ignore tags are valid for all PHP/dependency versions | Tag for PHP 8.1 compat issue not needed on 8.2+ |
| No blanket ignores | `@phpstan-ignore-line` or `@phpstan-ignore-next-line` without specific identifier | Generic suppression hiding real problems |
| Baseline currency | `phpstan-baseline.neon` entries still correspond to actual errors | Stale baseline entries |

**Checkpoint template:**

```yaml
- id: XX-STAN-01
  domain: code-quality
  prompt: |
    Verify that all @phpstan-ignore tags in the codebase:
    1. Suppress errors that actually exist (not stale/outdated tags)
    2. Use specific error identifiers, not blanket ignores
    3. Are necessary across ALL supported PHP and dependency versions
    4. Have comments explaining WHY the ignore is needed
    Report any ignore tags that appear unnecessary or overly broad.
  severity: warning
  desc: "PHPStan ignore tags must be valid and specific"
```

### Test Assertion Specificity

Skills dealing with testing must include checkpoints that verify:

| Checkpoint Focus | What to Verify | Example |
|-----------------|----------------|---------|
| Not just `assertTrue` | Tests use specific assertions, not generic boolean checks | `assertEquals` over `assertTrue($a == $b)` |
| Meaningful assertions | Tests assert meaningful values, not just "no exception thrown" | Actually checking output vs just running code |
| Refactoring resilience | Assertions survive refactoring without silently weakening | Assertion on class name that changed |
| Coverage of edge cases | Tests cover error paths, not just happy paths | Testing exception messages, error codes |

**Checkpoint template:**

```yaml
- id: XX-TEST-01
  domain: code-quality
  prompt: |
    Verify test assertion quality:
    1. Tests use specific assertions (assertEquals, assertSame, assertInstanceOf)
       not generic ones (assertTrue with comparison)
    2. Tests assert meaningful output values, not just absence of exceptions
    3. Tests would fail if the implementation behavior changed subtly
    4. Error/edge case paths have dedicated test methods
    Report any tests that could pass despite broken implementation.
  severity: warning
  desc: "Test assertions must be specific enough to catch regressions"
```

## Validating Checkpoint Coverage

The `/assess --review` command can identify skills with missing checkpoint coverage. When a real-world issue would not have been caught by existing checkpoints, it is classified as a `skill-gap`.

### Coverage Audit Workflow

1. **Identify the failure class** -- what kind of issue was missed?
2. **Map to coverage category** -- which category above does it fall into?
3. **Check existing checkpoints** -- does the skill's `checkpoints.yaml` have a checkpoint for this category?
4. **If missing, add checkpoint** -- use the templates above as starting points

### Minimum Coverage Matrix

| Skill Domain | API Compat | Mock Validity | PHPStan Ignores | Test Specificity |
|-------------|:---:|:---:|:---:|:---:|
| php-modernization | Required | Recommended | Required | Recommended |
| typo3-conformance | Required | Recommended | Required | Recommended |
| typo3-testing | Recommended | Required | Recommended | Required |
| typo3-extension-upgrade | Required | Recommended | Required | Recommended |
| security-audit | -- | -- | Recommended | -- |
| enterprise-readiness | -- | -- | -- | Recommended |

**Required** = must have at least one checkpoint in this category
**Recommended** = should have unless skill explicitly doesn't cover this domain
**--** = not applicable to this skill's scope

## Pre-Push Validation Gate

Every project should run local CI checks before pushing. The assessment framework can verify this via the `pre-push` domain.

### PP-01: Local CI Checks Passing

Before any `git push`, the following must have been run and passed:

| Tool | Command | What It Catches |
|------|---------|-----------------|
| PHPStan | `vendor/bin/phpstan analyse` | Type errors, missing methods, wrong args |
| PHPUnit | `vendor/bin/phpunit` | Broken tests, regressions |
| PHP-CS-Fixer | `vendor/bin/php-cs-fixer fix --dry-run` | Code style violations |
| Rector | `vendor/bin/rector process --dry-run` | Outdated patterns, needed migrations |

**Checkpoint template:**

```yaml
- id: PP-01
  type: command
  pattern: "test -f vendor/bin/phpstan && vendor/bin/phpstan analyse --no-progress"
  severity: error
  desc: "PHPStan analysis must pass locally"

- id: PP-02
  type: command
  pattern: "test -f vendor/bin/phpunit && vendor/bin/phpunit --no-coverage"
  severity: error
  desc: "Unit tests must pass locally"

- id: PP-03
  type: command
  pattern: "test ! -f vendor/bin/php-cs-fixer || vendor/bin/php-cs-fixer fix --dry-run --diff"
  severity: warning
  desc: "Code style must be clean (PHP-CS-Fixer)"

- id: PP-04
  type: command
  pattern: "test ! -f vendor/bin/rector || vendor/bin/rector process --dry-run"
  severity: warning
  desc: "Rector should report no pending changes"
```
