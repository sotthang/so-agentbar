---
name: so-spec-format
description: SPEC file format, naming rules, and status management for Planner and Reviewer agents.
user-invocable: false
---

# SO-ADK SPEC Format

## File Naming

```
specs/SPEC-{NNN}-{slug}.md
```

- `NNN`: zero-padded 3-digit sequence number
- `slug`: lowercase kebab-case feature name (max 5 words)
- Examples:
  - `specs/SPEC-001-user-login.md`
  - `specs/SPEC-002-payment-webhook.md`
  - `specs/SPEC-003-export-csv.md`

## Determining the Next Number

1. Check if `specs/` directory exists — if not, start at 001
2. List all files matching `SPEC-*.md`
3. Find the highest NNN and increment by 1

## SPEC File Template

```markdown
# SPEC-{NNN}: {Feature Name}

**Status**: Draft
**Created**: {YYYY-MM-DD}

## Goal

One sentence: what problem does this solve for the user?

## Requirements

- [ ] Requirement 1
- [ ] Requirement 2
- [ ] Requirement 3

## Out of Scope

- What this does NOT include (prevents scope creep)

## Technical Approach

- Key files to create or modify
- Libraries or patterns to use
- Data models or schema changes (if any)
- Integration points with existing code

## Acceptance Criteria

- [ ] Criterion 1 — specific and testable
- [ ] Criterion 2 — specific and testable
- [ ] Criterion 3 — specific and testable
```

## Status Lifecycle

Update the `**Status**` field at each transition — do not leave it stale.

| Agent | Transition |
| ----- | ---------- |
| so-planner | Creates file → `Draft` |
| so-reviewer | User approves → `Approved` |
| so-architect | Design complete → `Architected` |
| so-tester | RED tests written → `Testing` |
| so-developer | Implementation started → `In Progress` |
| so-quality | Refactoring started → `Reviewing` |
| so-docs | Pipeline complete → `Done` |

The Orchestrator reads this status to resume interrupted pipelines across sessions.

## Writing Good Requirements

- Each requirement must be independently verifiable
- Use "The system shall..." or "User can..." phrasing
- Avoid "should", "may", "might" — use "must" or "can"

## Writing Good Acceptance Criteria

- Each criterion maps to at least one test case
- Criteria are binary: either done or not done
- Bad: "The login works correctly"
- Good: "User can log in with valid email+password and receives a JWT token"
