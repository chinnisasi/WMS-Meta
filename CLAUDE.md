# WMS Meta — Agent Operating Rules

WMS Meta is a **control-plane repo**, not an application. It gives an agent shared context and filesystem access to the child repos at once:

- `wms-fe` (frontend) → `workspace/core/frontend/wms-fe`
- `wms-be` (backend) → `workspace/core/backend/wms-be`
- `wms-mobile` (mobile) → `workspace/core/mobile/wms-mobile`

## Where a change belongs

Commit every change in the repo whose history it belongs to:

| Change | Commit inside |
| --- | --- |
| Frontend code, config, deps | `workspace/core/frontend/wms-fe` |
| Backend code, config, deps | `workspace/core/backend/wms-be` |
| Mobile code, config, deps | `workspace/core/mobile/wms-mobile` |
| Cross-repo initiative notes | `docs/initiatives/` (this repo) |
| Repo-specific durable notes, interface contracts | `docs/repos/<repo-id>/` (this repo) |
| Catalog/routing metadata | `docs/repo-catalog.yaml` (this repo) |

Never `git add -f` anything under `workspace/**` into this meta repo — a `hooks/pre-commit` guard blocks it. Child repos are independent git working trees with their own remotes.

## Design docs — read before writing code

`docs/design/` holds the durable design the whole system is built on. These are **not** per-story artifacts; they describe how this codebase works and are what make a story's spec short.

| Doc | Holds |
| --- | --- |
| `docs/design/SYSTEM-DESIGN.md` | High level: the three repos, the ledger-as-truth idea, request lifecycle, module map, the inventory core, offline, outbox, background jobs |
| `docs/design/IMPLEMENTATION-GUIDE.md` | Low level: the command skeleton and why its order is load-bearing, the four type boundaries, the migration checklist, vocabulary pattern, test conventions, error shape |
| `docs/design/modules/<module>.md` | Per module: what it owns, its public seam, every command and its guards, key algorithms, invariants, events, and the gotchas that caused real defects |
| `docs/design/API-SURFACE.md` | Every route, grouped by owning module, with its capability and its error arms |
| `docs/design/PENDING.md` | Everything known-but-not-done, grouped by module — 65 deferred items and 33 open retro actions |
| `docs/repos/<repo>/README.md` | The interface contract — what each repo exposes and consumes |

**Every story spec MUST list the design docs in its `context:` frontmatter**, alongside the epic context:

```yaml
context:
  - '_bmad-output/implementation-artifacts/epic-<N>-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/<the module the story changes>.md'
```

**Before speccing, read the module's section in `docs/design/PENDING.md`.** Several entries are already-diagnosed defects with the fix identified; folding one into related work is cheaper than scheduling it separately.

The implementation agent is dispatched with the spec as its sole source of truth and loads exactly what `context:` names. Omitting these means it re-derives the command skeleton, the migration checklist and the type boundaries from scratch — which is slow, varies per story, and is where the recurring review findings come from.

**Keep them current.** When a review finds a defect whose cause is a pattern nobody wrote down, the fix lands in `IMPLEMENTATION-GUIDE.md` as well as in the code.

## Cross-repo ordering rules

- **Backend first.** For a story that spans both repos, land additive backend changes (new endpoints, fields) before the frontend changes that consume them.
- **Meta repo last.** Code ships before the docs that describe it; `bun run workspace:push` enforces this order automatically.
- After a cross-repo change lands, update the interface contract in `docs/repos/wms-fe/README.md` (what the frontend consumes) and/or `docs/repos/wms-be/README.md` (what the backend exposes) — that contract is what lets the agent catch breakage *before* making a change.

## Git flow (PR-based)

`main` in all three repos is branch-protected: changes land via pull request, and in `wms-be`/`wms-fe` the CI checks (lint, tests, typecheck, build, drift guards) must pass before merge.

- Do story work on a feature branch named `feat/<story-key>` (e.g. `feat/1-2-tenant-registration-and-warehouse-creation`) in each repo that changes.
- Push the branch, then open a PR: `gh pr create`. Merge with `gh pr merge --squash --delete-branch` once checks pass, then `git pull` on `main`.
- Cross-repo ordering still applies: open and merge the backend PR before the frontend PR that consumes it; meta docs PR last.
- Direct pushes to `main` are permitted for the admin account (bypass), but should be reserved for trivial fixes — default to the PR flow.

## Workspace commands

- `bun run workspace:setup` — clone any registered repo that is missing locally
- `bun run workspace:status` — one-pass git status across all child repos
- `bun run workspace:push` — fetch, review (interactive in a TTY), push; backend first, meta last

Bun only — never `npm`/`yarn`/`pnpm` here.