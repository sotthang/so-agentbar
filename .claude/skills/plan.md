---
name: plan
description: Shortcut to run only the Planner agent and generate a SPEC. Claude normally triggers this automatically — use this for explicit control.
user-invocable: true
---

Run only the Planner agent for the following feature:

$ARGUMENTS

If no arguments provided, ask: "어떤 기능의 SPEC을 작성할까요?"

Invoke the `so-planner` agent using the Agent tool. When done, ask: "SPEC이 완성되었습니다. 전체 파이프라인을 계속 진행할까요?"
