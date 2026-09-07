# WMS Meta

WMS Meta is the control-plane repo for AI-assisted work across the WMS product: the `wms-fe` frontend and the `wms-be` backend.

This repo is not an application. It is the durable layer that gives an AI agent shared context and filesystem access to both child repos at once, so it can plan and make changes across both in a single session.

> **metarepo** (_n_): a repo that coordinates work across multiple child repos by giving agents shared cross-repo context and routing metadata, rather than being the main home of application code.

## What Lives Here

- `docs/repo-catalog.yaml` — the list of registered child repos (id, remote, local path, role, default branch)
- `docs/repos/<repo-id>/` — durable notes per child repo (architecture, cross-repo contracts, conventions)
- `docs/initiatives/` — durable notes for work that spans both repos
- `scripts/setup-workspace.ts` — clones every registered repo from `docs/repo-catalog.yaml` into `workspace/core/`
- `scripts/workspace-status.ts` — shows git status for every registered repo in one pass
- `scripts/workspace-push.ts` — pushes unpushed commits on each repo's **checked-out branch** (fetches from the remote first so ahead/behind is real; backend repos push first, meta repo last). `--dry-run` previews, `--only <id>` restricts to one repo, `--except <id>` excludes one (they are mutually exclusive). Never force-pushes; skips dirty (tracked changes), diverged, or behind-origin repos with a warning; untracked files never block a push. Exit codes: 0 = nothing failed, 1 = a push failed, 2 = bad arguments.
- `scripts/lib/push-triage.tsx` — the interactive review screen (`bun run workspace:push` shows it automatically in a terminal when at least one repo has a real choice to make — e.g. push a dirty-but-ahead repo, publish a branch with no upstream). Arrow keys move and change the action, `v` shows details, `enter` confirms, `q` keeps defaults; outside a TTY or with `--no-interactive` it never appears and the plain output runs instead. The UI only decides — it never runs git itself.
- `workspace/core/` — local clones of the registered repos (gitignored — not part of this repo's history)
- `CLAUDE.md` — operating rules for the agent, most importantly: which repo's git history a change belongs to

## Getting Started

1. Install dependencies and clone the registered child repos:

   ```bash
   bun install
   bun run workspace:setup
   ```

   This repo uses **bun only** (enforced by a `preinstall` check) — don't use `npm`/`yarn`/`pnpm`.

   This clones:
   - `wms-fe` → `workspace/core/frontend/wms-fe`
   - `wms-be` → `workspace/core/backend/wms-be`

2. (Optional) BMAD is not installed yet. To install it at this repo's root — one shared skill/config layer that can see and edit both repos:

   ```bash
   bunx bmad-method install --directory . --action install --modules bmm,tea,cis --tools claude-code
   ```

3. Create a feature branch here in the meta repo if you're tracking cross-repo initiative docs:

   ```bash
   git checkout -b <feature-name>
   ```

4. Before implementation starts, create matching feature branches inside `workspace/core/frontend/wms-fe` and `workspace/core/backend/wms-be` — those are independent git working trees with their own history and remotes.

5. Point the agent at this meta repo root. It can now read, edit, and commit in both `workspace/core/frontend/wms-fe` and `workspace/core/backend/wms-be` in the same session.

## Day-to-Day Workflow

- **Changing the frontend or backend?** Work inside `workspace/core/frontend/wms-fe` or `workspace/core/backend/wms-be` directly — each is its own git repo with its own remote and commits. This meta repo's git status does not reflect their status.
- **Changing something that spans both repos?** Note it under `docs/initiatives/` — repo map, shared acceptance criteria, rollout notes — so the context survives across sessions.
- **Changing routing/catalog metadata?** Edit `docs/repo-catalog.yaml` — e.g. to register a new repo or change a default branch.

## Using `workspace:push`

The main daily command. It fetches every repo, classifies each one, then pushes
the unpushed commits on the checked-out branch — backend repos first, the meta
repo last (see the ordering rule in `CLAUDE.md`).

```bash
bun run workspace:push                # fetch → review → push
bun run workspace:push -- --dry-run   # same flow, pushes nothing
bun run workspace:push -- --only wms-be         # restrict to one repo
bun run workspace:push -- --except wms-meta     # exclude one repo
bun run workspace:push -- --no-interactive      # plain output, no review screen
```

(With `bun run`, the extra `--` separates bun's flags from the script's.)

**The interactive review screen.** In a terminal, if at least one repo has a
real choice to make, a screen lists every repo with its state and action
before anything is pushed:

```
❯ wms-be  [main: ahead 2, 1 untracked]    →  push
  wms-fe  [main: ahead 1, 3 uncommitted]  →  skip
  wms-meta [main: ahead 1 / behind 2 (diverged), 1 uncommitted]  →  skip
```

| Key | Action |
| --- | --- |
| `↑` / `↓` (or `k` / `j`) | Move between repos |
| `←` / `→` | Change that repo's action |
| `v` | Show/hide details (unpushed commits, working tree, manual-fix command) |
| `enter` | Continue and run the actions shown |
| `q` or `Ctrl+C` | Quit, keeping the default actions |

- **Actions:** `skip`, `push`, and `push -u origin` (publish a branch with no
  upstream, or re-link one deleted on the remote).
- **Dirty-but-ahead repos** default to `skip`, but you can choose `push` — it
  is safe, because a push never touches the working tree. Committing first is
  still the cleaner habit.
- **Diverged / behind / not-cloned / detached-HEAD repos are skip-only** — the
  screen shows the fix command but never force-pushes or rebases for you.
- If `git fetch` fails (e.g. offline), every repo is flagged "ahead/behind may
  be stale" instead of quietly trusting old refs.
- Outside a terminal (CI, scripts, piped output) the screen never appears —
  plain output runs with the default actions. Exit codes: `0` nothing failed,
  `1` a push failed, `2` bad arguments.

## Adding Another Repo Later

Add an entry to `docs/repo-catalog.yaml` (id, path, remote, role, default_branch, status, docs_dir) and create a matching `docs/repos/<repo-id>/` folder. Re-run `bun run workspace:setup` — it clones only what's missing and skips repos that already exist locally.# WMS-FE
# WMS-Meta
