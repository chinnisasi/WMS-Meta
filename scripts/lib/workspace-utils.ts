import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import YAML from "yaml";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..", "..");

export interface RepoCatalogEntry {
	id: string;
	path: string;
	remote: string;
	role: string;
	default_branch: string;
	status: string;
	docs_dir: string;
}

export interface RepoCatalog {
	version: number;
	workspace_root: string;
	core_root: string;
	external_root: string;
	repos: RepoCatalogEntry[];
}

export type GitRepoState =
	| "in-sync"
	| "ahead"
	| "behind"
	| "diverged"
	| "no-upstream"
	| "no-commits"
	| "not-a-repo"
	| "git-error"
	| "detached"
	| "upstream-gone";

export interface GitStatus {
	branch: string | null;
	upstream: string | null;
	ahead: number;
	behind: number;
	/** Tracked modifications (staged/unstaged) — these block a push. */
	dirtyCount: number;
	/** Untracked files — informational only, they never conflict with a push. */
	untrackedCount: number;
	state: GitRepoState;
}

export function absoluteFromRelative(relativePath: string): string {
	return path.resolve(REPO_ROOT, relativePath);
}

export function loadCatalog(): RepoCatalog {
	const catalogPath = absoluteFromRelative("docs/repo-catalog.yaml");
	let raw: string;
	try {
		raw = fs.readFileSync(catalogPath, "utf8");
	} catch {
		throw new Error(`Repo catalog not found at ${catalogPath}`);
	}

	const catalog = YAML.parse(raw) as RepoCatalog | null;
	if (!catalog || !Array.isArray(catalog.repos)) {
		throw new Error(`Invalid repo catalog at ${catalogPath}: "repos" list is missing or malformed.`);
	}
	return catalog;
}

export function ensureDir(absolutePath: string): void {
	fs.mkdirSync(absolutePath, { recursive: true });
}

export function ensureWorkspaceRoots(catalog: RepoCatalog): void {
	ensureDir(absoluteFromRelative(catalog.core_root));
	ensureDir(absoluteFromRelative(catalog.external_root));
}

export function fileExists(absolutePath: string): boolean {
	return fs.existsSync(absolutePath);
}

export function isGitRepo(absolutePath: string): boolean {
	return fileExists(path.join(absolutePath, ".git"));
}

export function repoAbsolutePath(repo: RepoCatalogEntry): string {
	return absoluteFromRelative(repo.path);
}

export function runCommand(command: string, args: string[], options: object = {}): void {
	const result = spawnSync(command, args, {
		stdio: "inherit",
		cwd: REPO_ROOT,
		...options,
	});

	if (result.status !== 0) {
		throw new Error(`Command failed: ${command} ${args.join(" ")}`);
	}
}

/**
 * Environment for git calls whose output we parse. Pinning LC_ALL=C keeps
 * output like "ahead 1" and "No commits yet" in English regardless of the
 * user's locale — translated git would defeat the regexes below.
 */
export const GIT_PARSE_ENV = { ...process.env, LC_ALL: "C" };

/** Run a git command in a repo directory and return trimmed stdout, or null if git failed. */
export function gitCapture(repoDir: string, args: string[]): string | null {
	const result = spawnSync("git", args, { cwd: repoDir, encoding: "utf8", env: GIT_PARSE_ENV });
	return result.status === 0 ? result.stdout.trim() : null;
}

const EMPTY_STATUS: Omit<GitStatus, "state"> = {
	branch: null,
	upstream: null,
	ahead: 0,
	behind: 0,
	dirtyCount: 0,
	untrackedCount: 0,
};

/** Collect branch, upstream, ahead/behind and change counts for one repo. */
export function gitStatus(repoDir: string): GitStatus {
	if (!isGitRepo(repoDir)) {
		return { ...EMPTY_STATUS, state: "not-a-repo" };
	}

	const branchInfo = gitCapture(repoDir, ["status", "--short", "--branch"]);
	if (branchInfo === null) {
		// git itself failed (corrupt repo, permissions) — do not guess a state.
		return { ...EMPTY_STATUS, state: "git-error" };
	}

	const lines = branchInfo.split("\n").filter(Boolean);
	const dirtyCount = lines.filter((line) => !line.startsWith("##") && !line.startsWith("??")).length;
	const untrackedCount = lines.filter((line) => line.startsWith("??")).length;

	// First ## line, e.g. "## main...origin/main [ahead 1, behind 2]"
	const header = (lines.find((line) => line.startsWith("##")) ?? "").slice(3);

	if (/no branch/.test(header)) {
		return { ...EMPTY_STATUS, state: "detached" };
	}

	// Fresh repo: "## No commits yet on master" — the whole header is not a
	// branch name, so handle it before branch parsing.
	if (/No commits yet/.test(header)) {
		return { ...EMPTY_STATUS, state: "no-commits" };
	}

	const [branchPart, upstreamPart = ""] = header.split("...");
	const branch = branchPart.trim() || null;
	const upstream = upstreamPart ? upstreamPart.replace(/\s*\[.*\]\s*$/, "").trim() : null;
	const note = header.match(/\[(.+)\]/)?.[1] ?? "";

	const ahead = Number(note.match(/ahead (\d+)/)?.[1] ?? 0);
	const behind = Number(note.match(/behind (\d+)/)?.[1] ?? 0);

	let state: GitRepoState;
	if (!upstream) {
		state = "no-upstream";
	} else if (/\bgone\b/.test(note)) {
		// Upstream branch was deleted on the remote.
		state = "upstream-gone";
	} else if (ahead > 0 && behind > 0) {
		state = "diverged";
	} else if (ahead > 0) {
		state = "ahead";
	} else if (behind > 0) {
		state = "behind";
	} else {
		state = "in-sync";
	}

	return { branch, upstream, ahead, behind, dirtyCount, untrackedCount, state };
}

export function childDirectoryNames(absolutePath: string): string[] {
	if (!fileExists(absolutePath)) {
		return [];
	}

	return fs
		.readdirSync(absolutePath, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => entry.name);
}