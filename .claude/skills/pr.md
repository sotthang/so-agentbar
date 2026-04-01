---
name: pr
description: Shortcut to create a pull request with structured description. Claude normally triggers this automatically — use this for explicit control.
user-invocable: true
---

Create a pull request for the current branch.

1. Run `git diff main...HEAD` and `git log main...HEAD --oneline` to understand the changes
2. Draft PR title and body:

```
## Summary
- (2-3 bullet points)

## Changes
- Key files modified

## Test plan
- [ ] Tests written and passing
- [ ] Manual verification steps

## SPEC reference
- (SPEC file path if applicable)
```

3. Ask: "이 내용으로 PR을 생성할까요?"
4. Only create after user confirms via `gh pr create`
