#!/usr/bin/env bun

// Pushes every repo that has unpushed commits on its checked-out branch: all
// repos registered in docs/repo-catalog.yaml (backend first), then the meta
// repo itself last. Philosophy: skip, never force. Dirty or diverged repos are
// reported, not pushed. Untracked files never block a push.
//
// Interactive mode (Ink): when run in a terminal and at least one repo has a
// real choice to make (e.g. push a dirty-but-ahead repo, set a missing
// upstream), a triage UI lets you adjust each repo's action before anything
// runs. Pass --no-interactive (or run outside a TTY) to keep the plain output.

import { spawnSync } from "node:child_process";
import {
	REPO_ROOT,
	gitCapture,
	gitStatus,
	loadCatalog,
	repoAbsolutePath,
	type RepoCatalogEntry,
} from "./lib/workspace-utils.ts";
import {
	runPushTriage,
	stateNote,
	type PushDecision,
	type RepoReview,
} from "./lib/push-triage.tsx";

interface CliArgs {
	help: boolean;
	dryRun: boolean;
	noInteractive: boolean;
	only: string | null;
	except: string | null;
}

type PushTarget = {
	id: string;
	path: string;
	absolutePath: string;
};

type PushOutcome = "pushed" | "skipped" | "failed";

const META_TARGET: PushTarget = {
	id: "wms-meta",
	path: ".",
	absolutePath: REPO_ROOT,
};

const USAGE = `Usage: bun run workspace:push [--dry-run] [--only <id>] [--except <id>] [--no-interactive]

Pushes unpushed commits on each repo's checked-out branch. Fetches from the
remote first so ahead/behind reflects reality. Order: backend repos first,
then other registered repos, then the meta repo itself last.

In a terminal, repos with a real choice to make are reviewed interactively
(arrow keys to change the action per repo, v for details, enter to continue)
before anything is pushed. Pass --no-interactive to skip that screen.

  --dry-run          Show what would be pushed, push nothing
  --only <id>        Restrict to one repo id (e.g. wms-be, wms-fe, wms-meta)
  --except <id>      Exclude one repo id
  --no-interactive   Plain output, no review screen
  --help             Show this help

Exit codes: 0 = nothing failed, 1 = at least one push failed, 2 = bad arguments.

Safety: never force-pushes. Repos that are diverged, behind origin, not cloned,
or on a detached HEAD are skipped with a warning. Untracked files do not block
a push; uncommitted tracked changes block it unless you explicitly choose to
push anyway (safe — a push never touches the working tree).`;

function parseArgs(argv: string[]): CliArgs {
	const args: CliArgs = {
		help: false,
		dryRun: false,
		noInteractive: false,
		only: null,
		except: null,
	};
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "--help" || arg === "-h") {
			args.help = true;
		} else if (arg === "--dry-run") {
			args.dryRun = true;
		} else if (arg === "--no-interactive") {
			args.noInteractive = true;
		} else if (arg === "--only" || arg === "--except") {
			const value = argv[i + 1];
			if (!value || value.startsWith("--")) {
				console.error(`Flag ${arg} needs a repo id — got ${value ? `flag "${value}"` : "nothing"}.`);
				console.error(`\n${USAGE}`);
				process.exit(2);
			}
			if (arg === "--only") args.only = value;
			else args.except = value;
			i++;
		} else {
			console.error(`Unknown flag: ${arg}`);
			console.error(`\n${USAGE}`);
			process.exit(2);
		}
	}
	if (args.only && args.except) {
		console.error("--only and --except are mutually exclusive — use one or the other.");
		process.exit(2);
	}
	return args;
}

function buildTargets(catalog: ReturnType<typeof loadCatalog>, args: CliArgs): PushTarget[] {
	// Backend pushes before everything else: cross-repo stories are additive on
	// the backend first, and the frontend side consumes it (CLAUDE.md ordering rule).
	const rolePriority = (role: string) => (role === "backend" ? 0 : 1);
	const targets: PushTarget[] = catalog.repos
		.filter((repo) => repo.status === "active")
		.sort((a, b) => rolePriority(a.role) - rolePriority(b.role))
		.map((repo: RepoCatalogEntry) => ({
			id: repo.id,
			path: repo.path,
			absolutePath: repoAbsolutePath(repo),
		}));

	// Meta repo last: code ships before the docs that describe it.
	targets.push(META_TARGET);

	const allIds = targets.map((t) => t.id);

	if (args.only) {
		const matched = targets.filter((t) => t.id === args.only);
		if (matched.length === 0) {
			console.error(`--only "${args.only}" matched no repo. Known ids: ${allIds.join(", ")}`);
			process.exit(2);
		}
		return matched;
	}
	if (args.except) {
		if (!allIds.includes(args.except)) {
			console.error(`--except "${args.except}" matched no repo. Known ids: ${allIds.join(", ")}`);
			process.exit(2);
		}
		return targets.filter((t) => t.id !== args.except);
	}
	return targets;
}

/** Fetch so ahead/behind reflects the remote, not the last fetch. Returns
 *  false when the fetch failed (offline, unreachable remote) — the caller
 *  must then warn that the classification may be stale. */
function fetchRepo(target: PushTarget): boolean {
	const result = spawnSync("git", ["fetch", "--quiet"], {
		cwd: target.absolutePath,
		stdio: "ignore",
	});
	return result.status === 0;
}

/** Classifies a repo and gathers everything the triage UI and applier need.
 *  No git-mutating command runs here (fetch is best-effort and read-only). */
function reviewRepo(target: PushTarget, fetchFailed: boolean): RepoReview {
	const status = gitStatus(target.absolutePath);

	// For the detail view: local-only commits (empty when in sync) and the
	// working-tree summary. Both reads are best-effort. A failed log must not
	// read as "nothing to push" — say so instead.
	const unpushedCommits =
		status.state === "ahead" || status.state === "behind" || status.state === "diverged"
			? (() => {
					const log = gitCapture(target.absolutePath, ["log", "--oneline", "@{u}.."]);
					if (log === null) {
						return ["⚠ could not list unpushed commits — git log failed"];
					}
					return log.split("\n").filter(Boolean);
				})()
			: [];
	const statusLines =
		status.dirtyCount + status.untrackedCount > 0
			? (gitCapture(target.absolutePath, ["status", "--short"]) ?? "")
					.split("\n")
					.filter(Boolean)
			: [];

	const base = {
		id: target.id,
		path: target.path,
		absolutePath: target.absolutePath,
		branch: status.branch,
		ahead: status.ahead,
		behind: status.behind,
		dirtyCount: status.dirtyCount,
		untrackedCount: status.untrackedCount,
		unpushedCommits,
		statusLines,
		fetchFailed,
		note: null,
		advice: [],
	};

	switch (status.state) {
		case "no-commits":
			return {
				...base,
				state: "no-commits",
				options: ["skip"],
				defaultDecision: "skip",
				note: "fresh repo with no commits yet — nothing to push",
			};
		case "not-a-repo":
			return {
				...base,
				state: "not-a-repo",
				options: ["skip"],
				defaultDecision: "skip",
				note: "not cloned — run `bun run workspace:setup`",
			};
		case "git-error":
			return {
				...base,
				state: "git-error",
				options: ["skip"],
				defaultDecision: "skip",
				note: "git status failed in this repo — check it manually before pushing",
			};
		case "detached":
			return {
				...base,
				state: "detached",
				options: ["skip"],
				defaultDecision: "skip",
				note: "repo is on a detached HEAD — nothing to push; check out a branch first",
			};
		case "no-upstream":
		case "upstream-gone":
			return {
				...base,
				state: status.state,
				options: ["skip", "push-upstream"],
				defaultDecision: "skip",
				note:
					status.state === "no-upstream"
						? "branch has no upstream — can push -u origin to publish it"
						: "upstream branch was deleted on the remote — can re-link it with push -u origin",
				advice: status.branch
					? [`git -C ${target.absolutePath} push -u origin ${status.branch}`]
					: [],
			};
		case "in-sync":
			return {
				...base,
				state: "in-sync",
				options: ["skip"],
				defaultDecision: "skip",
			};
		case "behind":
		case "diverged":
			return {
				...base,
				state: status.state,
				options: ["skip"],
				defaultDecision: "skip",
				note: "local branch is behind origin — pull/rebase first, then re-run",
				advice: [`git -C ${target.absolutePath} pull --rebase`],
			};
		case "ahead":
			return {
				...base,
				state: "ahead",
				options: ["skip", "push"],
				defaultDecision: status.dirtyCount > 0 ? "skip" : "push",
				note:
					status.dirtyCount > 0
						? "has uncommitted tracked changes — pushing anyway is safe (a push never touches the working tree), but committing first is cleaner"
						: null,
			};
	}
}

function describeReview(review: RepoReview): string {
	// Same labels as the Ink UI — one source of truth in push-triage.tsx.
	return stateNote(review);
}

/** Runs the decision the triage made for one repo. Returns its outcome. */
function applyDecision(review: RepoReview, decision: PushDecision, dryRun: boolean): PushOutcome {
	console.log(`\n${review.path} (${review.id})  ${describeReview(review)}`);
	if (review.fetchFailed) {
		console.log("  ⚠ git fetch failed (offline?) — ahead/behind may be based on stale refs");
	}

	switch (review.state) {
		case "no-commits":
			console.log("  ✓ fresh repo with no commits yet — nothing to push");
			return "skipped";
		case "not-a-repo":
			console.log("  ⚠ not cloned — run `bun run workspace:setup`");
			return "skipped";
		case "git-error":
			console.log("  ⚠ git status failed in this repo — check it manually before pushing");
			return "skipped";
		case "detached":
			console.log("  ⚠ repo is on a detached HEAD — nothing to push; check out a branch first");
			return "skipped";
		case "behind":
		case "diverged":
			console.log("  ⚠ local branch is behind origin — pull/rebase first, then re-run.");
			console.log(`    git -C ${review.absolutePath} pull --rebase`);
			return "skipped";
		case "in-sync":
			console.log("  ✓ nothing to push");
			return "skipped";
	}

	// From here on the repo is ahead: push, push-upstream, or skip are all real.
	if (decision === "skip") {
		if (review.state === "no-upstream" || review.state === "upstream-gone") {
			console.log(
				`  ⚠ ${review.state === "no-upstream" ? "branch has no upstream" : "upstream branch was deleted on the remote"} — skipped.`,
			);
			if (review.branch) {
				console.log(`    git -C ${review.absolutePath} push -u origin ${review.branch}`);
			}
		} else if (review.dirtyCount > 0) {
			console.log("  ⚠ has uncommitted tracked changes — commit them first; not pushing anything.");
		} else {
			console.log("  ⚠ skipped — you chose not to push this repo (nothing is blocking it).");
		}
		return "skipped";
	}

	if (review.dirtyCount > 0) {
		console.log("  (pushing with uncommitted tracked changes — safe, the working tree is untouched)");
	}
	if (review.untrackedCount > 0) {
		console.log(`  (note: ${review.untrackedCount} untracked file(s) left unpushed — commit or ignore them)`);
	}

	if (dryRun) {
		const commits = gitCapture(review.absolutePath, ["log", "--oneline", "@{u}.."]);
		if (commits === null) {
			console.log("  ⚠ could not list unpushed commits — dry run incomplete for this repo");
			return "failed";
		}
		for (const line of commits.split("\n").filter(Boolean)) {
			console.log(`  would push  ${line}`);
		}
		return "pushed";
	}

	const gitArgs =
		decision === "push-upstream" && review.branch
			? ["push", "-u", "origin", review.branch]
			: ["push"];
	const result = spawnSync("git", gitArgs, { cwd: review.absolutePath, stdio: "inherit" });
	return result.status === 0 ? "pushed" : "failed";
}

try {
	const catalog = loadCatalog();
	const args = parseArgs(process.argv.slice(2));

	if (args.help) {
		console.log(USAGE);
		process.exit(0);
	}

	const targets = buildTargets(catalog, args);

	if (args.dryRun) {
		console.log("Dry run — nothing will be pushed.\n");
	}

	// Phase 1 — review: fetch and classify every repo, mutate nothing.
	const reviews = targets.map((target) => {
		const fetched = fetchRepo(target);
		return reviewRepo(target, !fetched);
	});

	// Phase 2 — triage: interactive review only when it can change something.
	// Dry run included: the preview should offer the same choices the real run
	// would, not silently show a different plan.
	const interactive =
		!args.noInteractive &&
		Boolean(process.stdout.isTTY) &&
		Boolean(process.stdin.isTTY) &&
		reviews.some((review) => review.options.length > 1);

	let decisions: Record<string, PushDecision> = {};
	if (interactive) {
		decisions = await runPushTriage(reviews);
		console.log("");
	}

	// Phase 3 — apply: push (or report) each repo in order.
	const counts = { pushed: 0, skipped: 0, failed: 0 };
	for (const review of reviews) {
		const decision = decisions[review.id] ?? review.defaultDecision;
		const outcome = applyDecision(review, decision, args.dryRun);
		counts[outcome]++;
	}

	console.log("");
	console.log(
		args.dryRun
			? `Would push ${counts.pushed}, skipped ${counts.skipped}, failed ${counts.failed} (of ${targets.length} repo(s)) — dry run, nothing was pushed.`
			: `Pushed ${counts.pushed}, skipped ${counts.skipped}, failed ${counts.failed} (of ${targets.length} repo(s)).`,
	);
	process.exit(counts.failed === 0 ? 0 : 1);
} catch (error) {
	console.error(error instanceof Error ? error.message : error);
	process.exit(1);
}