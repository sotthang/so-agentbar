---
name: simplify
description: Shortcut to run only the Quality agent for refactoring. Claude normally triggers this automatically — use this for explicit control.
user-invocable: true
---

Run only the Quality agent on the following target:

$ARGUMENTS (file path, function name, or leave empty for recently modified files)

Invoke the `so-quality` agent using the Agent tool.
