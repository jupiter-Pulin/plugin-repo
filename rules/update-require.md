# Version Update Requirements

When preparing a release PR or when package behavior / user-facing artifacts change, bump the version in `package.json`.

> Transient edits, local experiments, and work-in-progress commits do NOT require a version bump.

## Version Bump Rules

Use `AskUserQuestion` to ask the user which version segment to bump based on the scope of changes. Format: `MAJOR.MINOR.PATCH`

| Segment | Position | When to bump | Example |
|---------|----------|--------------|---------|
| `MAJOR` | First    | Breaking changes or large-scale rewrites | Removed public API, changed config schema |
| `MINOR` | Middle   | New features, non-breaking additions | New skill, new command |
| `PATCH` | Last     | Bug fixes, small edits, documentation | Typo fix, corrected rule wording |

Always provide a **recommendation** when asking.

### Non-Interactive Fallback

If running in a non-interactive context (CI, automated pipeline), skip `AskUserQuestion` and auto-select bump level using this decision table:

| Condition | Auto-select |
|-----------|-------------|
| Any breaking change | `MAJOR` |
| New feature, no breaking change | `MINOR` |
| Bug fix / docs / chore only | `PATCH` |

Log the rationale: `version bump: PATCH — bug fix only (auto-selected)`.
