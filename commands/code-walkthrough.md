---
description: Diff-based code walkthrough — function-level logic explanation + test coverage map for review preparation
argument-hint: '[files...] [--base <ref>] [--top <N>] [--module <name>] [--save [path]] [--verify]'
allowed-tools: Read, Grep, Glob, Bash(git:*)
---

⚠️ **Must read and follow the skill below before executing this command:**

@skills/code-walkthrough/SKILL.md
@skills/code-walkthrough/references/output-template.md

## Context

- Git status: !`git status -sb`
- Changed files: !`git diff --name-only HEAD | head -20`

## Task

Walk through code changes — explain function logic, map test coverage, identify gaps.

### Arguments

```
$ARGUMENTS
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `[files...]` | Specific files to walkthrough | All changed files |
| `--base <ref>` | Diff base reference | `HEAD` (uncommitted) |
| `--top <N>` | Max functions for deep walkthrough | `10` |
| `--module <name>` | Filter by module/directory name | All |
| `--save [path]` | Persist output to file | Ephemeral |
| `--verify` | Add Codex verification of accuracy | Off |

### Workflow

```
Collect diff → Inventory scan → Deep walkthrough (top-N) → Test mapping → Gaps report
```

1. **Collect changes**: Determine scope from args or `git diff`
2. **Inventory scan**: List all changed files + functions with complexity classification
3. **Deep walkthrough**: Step-by-step logic for top-N complex functions, with Mermaid for High complexity
4. **Test mapping**: Match each walked-through function to its test cases + boundary conditions
5. **Uncovered risks**: Identify untested branches, missing edge cases

### Key Rules

- **Complexity drives depth**: High = full walkthrough + Mermaid, Medium = step-by-step, Low = inventory only
- **Mermaid diagram selection**: flowchart for branching, sequenceDiagram for multi-module, stateDiagram for state machines
- **Test mapping must reference actual test file:line** — no guessing

## Examples

```bash
# Walkthrough all uncommitted changes
/code-walkthrough

# Walkthrough full branch diff
/code-walkthrough --base origin/main

# Focus on specific module
/code-walkthrough --module src/service/order/

# Limit deep analysis to top 5
/code-walkthrough --top 5

# Save output for PR description
/code-walkthrough --save docs/walkthrough.md

# With Codex accuracy verification
/code-walkthrough --verify
```
