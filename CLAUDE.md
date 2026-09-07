# WMS Meta — Agent Operating Rules

WMS Meta is a **control-plane repo**, not an application. It gives an agent shared context and filesystem access to the child repos at once:

- `wms-fe` (frontend) → `workspace/core/frontend/wms-fe`
- `wms-be` (backend) → `workspace/core/backend/wms-be`

## Where a change belongs

Commit every change in the repo whose history it belongs to:

| Change | Commit inside |
| --- | --- |
| Frontend code, config, deps | `workspace/core/frontend/wms-fe` |
| Backend code, config, deps | `workspace/core/backend/wms-be` |
| Cross-repo initiative notes | `docs/initiatives/` (this repo) |
| Repo-specific durable notes, interface contracts | `docs/repos/<repo-id>/` (this repo) |
| Catalog/routing metadata | `docs/repo-catalog.yaml` (this repo) |

Never `git add -f` anything under `workspace/**` into this meta repo — a `hooks/pre-commit` guard blocks it. Child repos are independent git working trees with their own remotes.

## Cross-repo ordering rules

- **Backend first.** For a story that spans both repos, land additive backend changes (new endpoints, fields) before the frontend changes that consume them.
- **Meta repo last.** Code ships before the docs that describe it; `bun run workspace:push` enforces this order automatically.
- After a cross-repo change lands, update the interface contract in `docs/repos/wms-fe/README.md` (what the frontend consumes) and/or `docs/repos/wms-be/README.md` (what the backend exposes) — that contract is what lets the agent catch breakage *before* making a change.

## Workspace commands

- `bun run workspace:setup` — clone any registered repo that is missing locally
- `bun run workspace:status` — one-pass git status across all child repos
- `bun run workspace:push` — fetch, review (interactive in a TTY), push; backend first, meta last

Bun only — never `npm`/`yarn`/`pnpm` here.