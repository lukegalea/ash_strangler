<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_strangler`. It lets a legacy schema and a new Ash schema exist
over the same PostgreSQL rows at the same time.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- The mapping is one declaration: the `strangler do ... end` block on the
  resource. The view, the triggers, the index, the backfill, the drift
  reconciler, and the notification bridge all derive from it. Nothing is kept
  in sync by hand.
- Every guarantee rests on one database, and therefore one transaction. Work
  across two databases is change data capture and is out of scope.
- The string-based mapping DSL is gone, not deprecated. A 0.1 mapping does not
  compile, and the error names its replacement.
- The suite runs against a real PostgreSQL, not a mock. `mix test` needs a
  server on `localhost:5432`, or set `DB_HOST` and `PGPORT`.
- `CHANGELOG.md` keeps a hand-written Unreleased section, because the package
  does not use git_ops yet.
- Changes are judged against the 26 Iron Laws. Read "The iron laws and the
  judge" in `usage-rules.md`.

## Before you finish

CI calls the shared `ash-project/ash` `ash-ci.yml` workflow, with Postgres 16
and the REUSE check on. Run `mix test` and `reuse lint` before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
