# LLM Rubric: dependency-compatibility Domain

This file contains detailed rubrics for LLM-based reviews in the dependency-compatibility domain.
Reference specific sections using markdown anchors (e.g., `assets/llm-rubric-dependency-compatibility.md#api-compatibility`).

---

## api-compatibility

### Checkpoint: Verify API Compatibility Across Declared Versions

**Requirement:** All method calls, constructor invocations, and class references must be compatible with every major version declared in `composer.json` constraints.

**Verification Steps:**

1. Parse `composer.json` to find dependencies with multi-major-version constraints (e.g., `^2.0 || ^3.0`)
2. For each such dependency, identify all usages in `Classes/` or `src/`
3. Check whether called methods exist on the relevant interfaces/classes across all declared versions
4. Flag any usage that is version-specific without conditional logic

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | All API calls are compatible with all declared major versions, or version-conditional logic is used |
| `fail` | Code calls methods that only exist in some declared versions without version guards |
| `skip` | No multi-major-version constraints in composer.json |

**Evidence Required:**

- List the multi-version constraints found
- For each version-specific API call, quote the file and line
- Note whether version-conditional logic exists

---

## mock-validity

### Checkpoint: Verify Test Mocks Match Real Interfaces

**Requirement:** Test mocks and stubs must reference methods that actually exist on the interfaces or classes being mocked.

**Verification Steps:**

1. Find all test files using `getMockBuilder()`, `createMock()`, `prophesize()`, or similar
2. For each mock, identify the target class/interface
3. Verify that each `->method('X')` call references a method that exists on the target
4. Verify that `->willReturn()` values match expected return types
5. Cross-reference with all declared major versions of the dependency

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | All mocked methods exist on their target interfaces across all supported versions |
| `fail` | Any mock references a method that does not exist on the target in at least one supported version |
| `skip` | No test mocks found, or no multi-version dependencies |

**Evidence Required:**

- List each mock with its target class and mocked methods
- Flag methods that don't exist on the target in specific versions
- Quote the test file and line number

---

## phpstan-ignore-validity

### Checkpoint: Verify PHPStan Ignore Tags Are Valid

**Requirement:** All `@phpstan-ignore` tags must suppress real errors and work correctly across all supported versions.

**Verification Steps:**

1. Find all `@phpstan-ignore-*` annotations in source and test files
2. Verify each tag suppresses an error that actually occurs
3. Check that tags use specific error identifiers (not blanket ignores)
4. Verify tags are necessary across all supported PHP and dependency versions
5. Check for explanatory comments on each ignore tag

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | All ignore tags suppress real errors, use specific identifiers, and include comments |
| `fail` | Any ignore tag is stale, overly broad, or missing an explanation |
| `skip` | No PHPStan ignore tags found |

**Evidence Required:**

- List each ignore tag with its location and suppressed error
- Flag tags that appear unnecessary (no corresponding error)
- Flag tags using generic suppression without identifiers

---

## test-assertion-quality

### Checkpoint: Verify Test Assertions Are Specific

**Requirement:** Tests must use specific assertions that would catch subtle implementation changes.

**Verification Steps:**

1. Scan test files for assertion patterns
2. Flag `assertTrue($a == $b)` patterns (should be `assertEquals`)
3. Flag tests with no assertions (only testing "no exception")
4. Flag overly generic assertions that would pass despite behavior changes
5. Check that error paths have dedicated test methods

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | Tests use specific assertions, cover error paths, and would catch regressions |
| `fail` | Tests use generic assertions, lack error path coverage, or could pass despite broken behavior |
| `skip` | No test files found |

**Evidence Required:**

- Count of specific vs generic assertions
- List any tests with no assertions
- List any tests that would pass despite implementation changes
- Note coverage of error/edge case paths

---

## pre-push-validation

### Checkpoint: Verify Local CI Checks Were Run

**Requirement:** All local CI checks (PHPStan, PHPUnit, PHP-CS-Fixer, Rector) must have been run and passing before code is pushed.

**Verification Steps:**

1. Check for the presence of CI tool configurations (phpstan.neon, phpunit.xml, .php-cs-fixer.php, rector.php)
2. For each configured tool, verify it can run without errors
3. Check for a pre-push hook or CI script that enforces these checks
4. Verify that all tools pass on the current codebase state

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | All configured CI tools pass, and a pre-push hook or equivalent exists |
| `fail` | Any CI tool fails, or no enforcement mechanism exists |
| `skip` | No PHP CI tools configured |

**Evidence Required:**

- List configured CI tools and their results
- Note whether a pre-push hook exists
- Quote any CI tool errors
