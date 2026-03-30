# Dependency Compatibility Assessment

When a project's `composer.json` declares constraints spanning multiple major versions (e.g., `^2.0 || ^3.0`), the automated-assessment framework can trigger a **dependency compatibility** assessment to verify that the codebase actually works with each supported major version.

## Trigger Conditions

The assessment activates when ANY of these conditions are met in `composer.json`:

1. **`require` or `require-dev`** contains a constraint with `||` separating major versions
2. **`require`** uses a range like `>=2.0 <5.0` spanning multiple major versions
3. **`require`** uses `^` or `~` with a base version that is not the latest major

Examples that trigger:

```json
{
  "require": {
    "intervention/image": "^2.0 || ^3.0 || ^4.0",
    "typo3/cms-core": "^12.4 || ^13.4"
  }
}
```

## Assessment Workflow

For each dependency with multi-major-version constraints:

### Step 1: Determine Supported Major Versions

Parse the constraint to extract each major version range. For `^2.0 || ^3.0 || ^4.0`, the versions are `2.*`, `3.*`, `4.*`.

### Step 2: Install Each Major Version

For each major version, run:

```bash
# Create a temporary composer.json override or use --with flag
composer require "vendor/package:^MAJOR.0" --no-interaction --dry-run 2>&1
```

If `--dry-run` succeeds, proceed with actual install in a temporary directory:

```bash
cp -r . /tmp/compat-test-vMAJOR
cd /tmp/compat-test-vMAJOR
composer require "vendor/package:^MAJOR.0" --no-interaction 2>&1
```

### Step 3: Run PHPStan Against Each Version

```bash
vendor/bin/phpstan analyse --no-progress --error-format=json 2>&1
```

Record error count and specific errors per version.

### Step 4: Run Unit Tests Against Each Version

```bash
vendor/bin/phpunit --no-coverage 2>&1
```

Record test results (pass/fail/error counts) per version.

### Step 5: Compare Results

Flag version-specific failures:
- PHPStan errors that appear only with certain major versions
- Test failures that appear only with certain major versions
- Installation failures for declared-but-incompatible versions

## Key Checkpoints

### DC-01: Multi-Version Constraint Detection

- **Type**: `command`
- **What**: Detect `composer.json` constraints spanning multiple major versions
- **Severity**: `info` (detection only, not a failure)

### DC-02: All Declared Versions Installable

- **Type**: `command`
- **What**: Each major version in the constraint can be installed without conflicts
- **Severity**: `error`

### DC-03: PHPStan Clean Across All Versions

- **Type**: `llm_review`
- **What**: No version-specific PHPStan errors (methods missing, type mismatches)
- **Severity**: `error`

### DC-04: Tests Pass Across All Versions

- **Type**: `llm_review`
- **What**: No version-specific test failures
- **Severity**: `error`

### DC-05: API Compatibility Verified

- **Type**: `llm_review`
- **What**: Code does not call methods that exist in one major version but not another
- **Severity**: `error`

## Common Failure Patterns

### Method Existence Across Versions

```php
// intervention/image v2: $image->encode('webp')
// intervention/image v3: $image->toWebp()
// intervention/image v4: $image->encodeByMediaType('image/webp')
```

Assessment should flag when code uses methods specific to only one major version without version-conditional logic.

### Constructor Signature Changes

```php
// v2: new ImageManager(['driver' => 'gd'])
// v3: new ImageManager(new Driver())
// v4: new ImageManager(new Driver())
```

### PHPStan Ignore Tag Validity

PHPStan `@phpstan-ignore` tags that suppress errors on one version may mask real issues on another. Assessment should verify that ignore tags are necessary across all supported versions.

### Mock Validity in Tests

Test mocks must mock methods that exist on the interface/class across all supported versions. A mock for `->encode()` is invalid if the interface no longer has that method in a newer version.

## Report Format

```json
{
  "dependency": "intervention/image",
  "constraint": "^2.0 || ^3.0 || ^4.0",
  "versions_tested": [
    {
      "version": "2.*",
      "install": "pass",
      "phpstan_errors": 0,
      "test_result": "pass",
      "test_count": 42
    },
    {
      "version": "3.*",
      "install": "pass",
      "phpstan_errors": 3,
      "test_result": "fail",
      "test_count": 42,
      "failures": ["testImageOptimize: Call to undefined method encode()"]
    },
    {
      "version": "4.*",
      "install": "pass",
      "phpstan_errors": 0,
      "test_result": "pass",
      "test_count": 42
    }
  ],
  "version_specific_issues": [
    "Method encode() does not exist on Intervention\\Image\\Interfaces\\ImageInterface in v3"
  ]
}
```

## Integration with Assessment

This assessment is triggered automatically when the `/assess` command detects multi-major-version constraints. It can also be invoked directly:

```
/assess dependency-compatibility
```

The assessment adds its results to the standard compliance report under the `dependency-compatibility` domain.
