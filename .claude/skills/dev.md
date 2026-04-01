---
name: dev
description: Shortcut to start the full SO-ADK pipeline. Claude normally triggers this automatically from natural language — use this slash command for explicit control.
user-invocable: true
---

Start the full SO-ADK development pipeline for the following feature:

$ARGUMENTS

If no arguments provided, ask: "어떤 기능을 개발할까요?"

Follow the orchestration pipeline defined in CLAUDE.md exactly — invoke each agent in order using the Agent tool.
