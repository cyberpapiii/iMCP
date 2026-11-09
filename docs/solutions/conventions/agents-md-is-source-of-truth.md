---
title: AGENTS.md is the source of truth; CLAUDE.md is a pointer
date: 2026-08-21
category: conventions
module: agent-instruction-files
problem_type: convention
component: documentation
severity: medium
applies_when:
  - Editing or adding agent or contributor guidance
  - Choosing whether to update AGENTS.md or CLAUDE.md
  - Adding discoverability pointers for docs/solutions/
tags:
  - agents-md
  - claude-md
  - source-of-truth
  - agent-docs
  - conventions
---

# AGENTS.md is the source of truth; CLAUDE.md is a pointer

## Rule

`AGENTS.md` holds all agent and contributor guidance: the architecture
paragraph, `## Commands`, `## Key paths`, `## Records`, and
`## Finishing a change`.
`CLAUDE.md` is only this pointer, kept because some tools load that filename:

```markdown
# CLAUDE.md

This project's agent and contributor guidance lives in [AGENTS.md](AGENTS.md).
```

- Edit `AGENTS.md` for any standing instruction. Never copy the body back into
  `CLAUDE.md`, and never invert the pointer.
- New learnings go in `docs/solutions/<category>/` with YAML frontmatter
  (`module`, `tags`, `problem_type`). The `AGENTS.md` Records table is their
  only pointer.

## Why

The repo once held the body in `CLAUDE.md` with `AGENTS.md` as the pointer
(`plans/005-add-agent-and-contributor-docs.md` and
`plans/035-docs-truth-pass.md`).
Two bodies drift the first time someone edits only one of them, and a
flipped pointer leaves one tool family reading a file that no longer holds
the guidance. One body and one pointer give every tool the same commands and
key paths.
