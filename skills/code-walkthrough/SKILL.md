---
name: code-walkthrough
description: "Diff-based code walkthrough for review preparation. Use when: after feature-dev/bug-fix to understand code changes before reviewing, onboarding junior engineers to a changeset. Not for: explaining arbitrary existing code (use codex-explain), architecture overview (use code-explore), code review (use codex-code-review). Output: function-level walkthrough + logic diagrams + test coverage map."
allowed-tools: Read, Grep, Glob, Bash(git:*)
---

# Code Walkthrough Skill

## Trigger

- Keywords: code walkthrough, explain changes, walk through code, explain diff, review preparation, understand changes, what changed

## When NOT to Use

| Scenario | Alternative |
|----------|-------------|
| Explain arbitrary existing code | `/codex-explain` |
| Architecture overview | `/code-explore` |
| Code review (find issues) | `/codex-review-fast` |
| Test coverage gaps only | `/check-coverage` |
| Design-level spec | `/tech-spec` |

## Positioning

```
tech-spec (before code)     code-walkthrough (after code)     codex-explain (any time)
─────────────────────────  ───────────────────────────────  ──────────────────────────
"How to build it"           "How the built code works"       "What does this code mean"
Architecture + API + Model  Function logic + Test mapping    Single file/function
For decision-making         For review preparation           For understanding
Persisted document          Ephemeral (default)              Ephemeral
```

## Workflow

```
Collect diff → Inventory scan → Deep walkthrough (top-N) → Test mapping → Gaps report
```

### Step 1: Collect Changes

Determine scope from arguments or auto-detect:

| Input | Collection |
|-------|------------|
| No args | `git diff HEAD --name-only` (uncommitted) |
| `--base <ref>` | `git diff <ref>..HEAD --name-only` |
| `<file ...>` | Specified files only |

Read full diff: `git diff [scope] --no-color`

### Step 2: Inventory Scan (Pass 1)

For each changed file, extract:
- File path + change type (new/modified/deleted)
- Changed function/method names (from diff hunks)
- One-sentence summary per function

Classify complexity:
- **High**: contains loops, recursion, state machines, complex conditionals (3+ branches), algorithm logic
- **Medium**: business logic with branching, data transformation
- **Low**: simple CRUD, config, imports, type definitions

### Step 3: Deep Walkthrough (Pass 2)

Select top-N functions by complexity (default N=10, override with `--top N`).

For each selected function:

1. **Purpose** — one sentence
2. **Step-by-step logic** — numbered walkthrough of the execution path
3. **Mermaid diagram** — only for High complexity (flowchart for branching, sequenceDiagram for multi-module interaction)
4. **Key decisions** — why this approach (if inferable from code context)

When `--module <name>` is specified, only walkthrough functions in matching files.

### Step 4: Test Coverage Mapping

For each walked-through function:
1. Search test files: `Grep` function name across `test/` directory
2. Map: behavior → test case → boundary conditions covered
3. List which edge cases each test targets

### Step 5: Uncovered Risks

Identify:
- Functions with no matching test
- Branches/error paths not covered by any test
- Edge cases mentioned in code (null checks, empty arrays, boundary values) without corresponding test assertions

## Output

See @references/output-template.md for full template.

Summary structure:

```markdown
## Code Walkthrough: [scope]

### 1. Change Inventory
| File | Type | Key Functions | Summary |
### 2. Core Logic Walkthrough
#### `functionName()` — path:line
Purpose / Step-by-step / Mermaid (if complex)
### 3. Test Coverage Map
| Behavior | Test Case | Boundary Conditions |
### 4. Uncovered Risks
- Untested branches / missing edge cases
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `[files...]` | Specific files to walkthrough | All changed files |
| `--base <ref>` | Diff base reference | `HEAD` (uncommitted) |
| `--top <N>` | Max functions for deep walkthrough | `10` |
| `--module <name>` | Filter by module/directory name | All |
| `--save [path]` | Persist output to file | Ephemeral |
| `--verify` | Add Codex verification of walkthrough accuracy | Off |

## Verification

- [ ] All changed functions listed in inventory
- [ ] High-complexity functions have step-by-step walkthrough
- [ ] Mermaid diagrams render correctly (flowchart/sequenceDiagram)
- [ ] Test mapping references actual test file:line
- [ ] Uncovered risks are actionable (not vague)

## References

- Output template: `references/output-template.md`

## Examples

```
Input: /code-walkthrough
Action: git diff HEAD → inventory all changes → walkthrough top-10 complex functions → map tests → report gaps

Input: /code-walkthrough --base origin/main
Action: git diff origin/main..HEAD → full branch walkthrough

Input: /code-walkthrough src/service/order/ --top 5
Action: walkthrough only order service, top 5 functions

Input: /code-walkthrough --save docs/walkthrough.md
Action: walkthrough → persist to file

Input: /code-walkthrough --verify
Action: walkthrough → Codex independently verifies accuracy of explanations
```
