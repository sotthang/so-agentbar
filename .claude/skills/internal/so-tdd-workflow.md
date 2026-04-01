---
name: so-tdd-workflow
description: TDD RED-GREEN-REFACTOR cycle rules for Tester, Developer, and Quality agents.
user-invocable: false
---

# SO-ADK TDD Workflow

## The Three Phases

### RED — Write Failing Tests (so-tester)

Goal: have a test suite that clearly defines what "done" looks like, and all tests fail.

Rules:
- Write tests **before** any implementation exists
- Every acceptance criterion in the SPEC must have at least one test
- Tests must fail for the **right reason** — not a syntax error or missing import
- Cover three categories:
  - Happy path: normal expected usage
  - Edge cases: empty input, boundary values, large inputs
  - Error cases: invalid input, network failure, unexpected state
- Tests must be **independent** — no shared mutable state between tests
- Use the project's existing test framework and file naming conventions

Confirm RED:
```
RED ✅ — {N} tests written, all failing as expected.
Reason for failure: [implementation does not exist / function not defined / etc.]
```

---

### GREEN — Make Tests Pass (so-developer)

Goal: write the minimum code to make all tests pass. Nothing more.

Rules:
- Implement **only** what is needed to pass the tests
- Do **not** add features, abstractions, or optimizations not required by the tests
- Do **not** modify tests to make them pass — fix the implementation
- Run tests after every meaningful change
- If tests still fail after a fix, analyze the failure message before trying again

Confirm GREEN:
```
GREEN ✅ — {N}/{N} tests passing.
```

If stuck after 3 attempts on the same failure, report:
```
⚠️ Stuck on: {test name}
Failure: {error message}
Attempted fixes: {list}
Need guidance.
```

---

### REFACTOR — Improve Without Breaking (so-quality)

Goal: improve code quality without changing any behavior. All tests must still pass.

Rules:
- Run the full test suite **before** starting refactor — confirm GREEN baseline
- Make one refactor change at a time, run tests after each change
- Stop immediately if any test turns RED — revert the last change
- Only fix real problems — do not restyle code that is already clear

What counts as a real problem:
- Duplicated logic (same code in 2+ places)
- Unclear names (single-letter vars, misleading names)
- Functions doing more than one thing
- Unused imports or dead code
- Missing error handling at system boundaries

Confirm REFACTOR:
```
REFACTOR ✅ — {N}/{N} tests still passing.
Changes: {list of changes made}
```
