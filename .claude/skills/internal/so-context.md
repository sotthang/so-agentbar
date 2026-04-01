---
name: so-context
description: Codebase context mapper. Scans the project to produce a focused file map for agents. Load this before starting any task in an unfamiliar or large codebase.
user-invocable: false
---

# SO-ADK Context Mapper

Before doing your core work, build a context map so you read only the files that matter.

## When to use this

Use this skill when:
- The codebase has more than ~10 files
- You don't already know which files are relevant to the task
- You are starting a new task (not continuing from a previous agent's output)

Skip this skill when:
- The previous agent already passed you a list of relevant files
- The task is clearly scoped to one specific file

## Process

1. **Detect project type** — read `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `build.gradle`, etc.
2. **Scan entry points** — find `main`, `app`, `index`, `server`, `cmd/` or equivalent
3. **Identify relevant files** — based on the task description, find files likely to be affected:
   - Grep for keywords from the task (function names, route names, model names)
   - Follow imports from entry points to at most 2 levels deep
   - Check test files for existing coverage of the area

4. **Output the context map** (keep it concise — max 15 files):

```text
## Context Map

### Project type
{language} / {framework} — {brief description}

### Entry points
- `src/main.py` — application entry
- `src/api/routes.py` — HTTP routes

### Relevant files for this task
- `src/users/service.py` — user business logic (likely to change)
- `src/users/models.py` — user data model
- `src/users/repository.py` — DB access layer
- `tests/test_users.py` — existing tests for this area

### Test framework
pytest / jest / go test / etc.

### Patterns observed
- Repository pattern for data access
- Service layer for business logic
- Pydantic models for validation
```

## Rules

- **Max 15 files** — if more seem relevant, include the most important and note the rest
- **No reading file content yet** — just identify paths and their role
- **Note the test framework** — all agents need to know this
- **Note existing patterns** — agents should follow them, not invent new ones
