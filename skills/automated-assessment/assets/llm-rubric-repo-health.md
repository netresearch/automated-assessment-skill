# LLM Rubric: repo-health Domain

This file contains detailed rubrics for LLM-based reviews in the repo-health domain.
Reference specific sections using markdown anchors (e.g., `references/llm-rubric.md#badge-order`).

---

## badge-order

### Checkpoint: Verify README Badge Ordering

**Requirement:** Badges in README.md must follow the standard order for TYPO3 extension projects.

**Expected Order:**

```markdown
<!-- Row 1: CI/Quality badges -->
[![CI](...)][ci]
[![codecov](...)][codecov]
[![Documentation](...)][docs]

<!-- Row 2: Security badges -->
[![OpenSSF Scorecard](...)][scorecard]
[![OpenSSF Best Practices](...)][bestpractices]
[![SLSA 3](...)][slsa]

<!-- Row 3: Standards badges -->
[![PHPStan](...)][phpstan]
[![PHP 8.x+](...)][php]
[![TYPO3 vXX](...)][typo3]
[![License](...)][license]
[![Latest Release](...)][release]

<!-- Row 4: TYPO3 TER badges (if published to TER) -->
![Composer](https://typo3-badges.dev/badge/EXT_KEY/composer/shields.svg)
![Downloads](https://typo3-badges.dev/badge/EXT_KEY/downloads/shields.svg)
```

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | Badges are present and follow the expected row grouping |
| `fail` | Badges are out of order OR mixing rows (e.g., security badge in CI row) |
| `skip` | No badges present (separate checkpoint handles badge existence) |

**Evidence Required:**
- Quote the actual badge order from README.md
- Identify which badges are misplaced if failing

---

## readme-structure

### Checkpoint: Verify README Has Standard Sections

**Requirement:** README.md should have clear sections covering essential topics.

**Required Sections:**

1. **Header** - Extension name, badges, brief description
2. **Installation** - Composer command, TER link, or manual installation
3. **Configuration** - TypoScript setup, Extension Manager settings, or "no configuration needed"
4. **Usage** - How to use the extension (examples, screenshots)
5. **Development** - How to contribute, run tests, lint code
6. **License** - License type and link
7. **Credits** (optional) - Contributors, sponsors

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | At least Installation, Configuration/Usage, and License sections exist |
| `fail` | Missing Installation OR License section |
| `skip` | README.md doesn't exist (separate checkpoint) |

**Evidence Required:**
- List the section headers found in README.md
- Note which required sections are missing

---

## branding-compliance

### Checkpoint: Verify Netresearch Branding

**Requirement:** Project follows Netresearch branding guidelines.

**Checklist:**

1. **Logo**: Extension icon uses Netresearch brand color `#2F99A4` as primary
2. **Description**: Repository description ends with `- by Netresearch`
3. **Credits**: README credits Netresearch appropriately
4. **Colors**: Any custom UI uses brand colors:
   - Primary: `#2F99A4` (teal)
   - Accent: `#FF4D00` (orange)
   - Neutral: `#585961` (gray)

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | At least description format and README credits are correct |
| `fail` | Description doesn't follow format OR no Netresearch mention |
| `skip` | Not a Netresearch project |

**Evidence Required:**
- Quote the repository description
- Quote the credits/attribution section from README

---

## agents-md-accuracy

### Checkpoint: Verify AGENTS.md Accuracy

**Requirement:** AGENTS.md content must match actual codebase state.

**Verification Steps:**

1. **File listings** - Do documented files exist?
2. **Command listings** - Do Makefile targets exist?
3. **Module counts** - Do numbers match actual file counts?
4. **Descriptions** - Do module descriptions match docstrings?

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | All documented files exist, commands work, counts are accurate |
| `fail` | Any documented file doesn't exist OR command is invalid |
| `skip` | No AGENTS.md file present |

**Evidence Required:**
- List any files documented but not found
- List any commands documented but not in Makefile
- Compare documented counts vs actual counts

---

## topics-compliance

### Checkpoint: Verify GitHub Repository Topics

**Requirement:** TYPO3 extension repositories must have required topics.

**Required Topics:**
- `typo3` (always required)
- `typo3-extension` (always required)
- `php` (always required)
- 2-5 domain-specific topics (e.g., `ckeditor`, `llm`, `ai`)

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | Has typo3, typo3-extension, php + at least 2 domain topics |
| `fail` | Missing any of the three required topics |
| `skip` | Not a TYPO3 extension (no ext_emconf.php) |

**Evidence Required:**
- List current repository topics
- Note which required topics are missing
- Suggest domain topics if fewer than 2

---

## description-format

### Checkpoint: Verify Repository Description Format

**Requirement:** GitHub repository description must follow the standard format.

**Format:** `<What the extension does> - by Netresearch`

**Examples:**
- Good: `TYPO3 extension for context-based content rendering - by Netresearch`
- Good: `AI-powered content writer for TYPO3 - by Netresearch`
- Bad: `Contexts extension` (too vague, missing branding)
- Bad: `TYPO3 extension for contexts` (missing branding)

**Evaluation Criteria:**

| Status | Condition |
|--------|-----------|
| `pass` | Description is descriptive AND ends with `- by Netresearch` |
| `fail` | Missing `- by Netresearch` suffix OR description is too vague |
| `skip` | Not a Netresearch repository |

**Evidence Required:**
- Quote the current repository description
- If failing, suggest improved description
