#!/usr/bin/env bun

import path from "node:path";
import {
	absoluteFromRelative,
	childDirectoryNames,
	ensureDir,
	ensureWorkspaceRoots,
	fileExists,
	isGitRepo,
	loadCatalog,
	repoAbsolutePath,
	runCommand,
	type RepoCatalog,
	type RepoCatalogEntry,
} from "./lib/workspace-utils.ts";

function pathExistsButNotGitRepo(absolutePath: string): boolean {
	return fileExists(absolutePath) && !isGitRepo(absolutePath);
}

function cloneOrSkipRepo(repo: RepoCatalogEntry): void {
	const targetPath = repoAbsolutePath(repo);

	if (isGitRepo(targetPath)) {
		console.log(`Skipping ${repo.path}; repository already exists.`);
		return;
	}

	if (pathExistsButNotGitRepo(targetPath)) {
		throw new Error(
			`Refusing to clone into ${repo.path}; path already exists and is not a git repository.`,
		);
	}

	ensureDir(path.dirname(targetPath));
	runCommand("git", ["clone", "--branch", repo.default_branch, repo.remote, targetPath]);
	console.log(`Cloned ${repo.remote} -> ${repo.path}.`);
}

function printWorkspaceSummary(catalog: RepoCatalog): void {
	console.log("");
	console.log("Workspace setup complete.");
	console.log(`Registered repos live under ${catalog.core_root}/{frontend,backend}/.`);
	console.log(`Use ${catalog.external_root}/ for ephemeral local repos that should not be cataloged.`);
	console.log("");

	const coreRoot = absoluteFromRelative(catalog.core_root);
	for (const bucket of childDirectoryNames(coreRoot)) {
		const bucketPath = absoluteFromRelative(`${catalog.core_root}/${bucket}`);
		console.log(`${catalog.core_root}/${bucket}`);
		for (const repoName of childDirectoryNames(bucketPath)) {
			console.log(`  ${catalog.core_root}/${bucket}/${repoName}`);
		}
		console.log("");
	}
}

try {
	const catalog = loadCatalog();
	ensureWorkspaceRoots(catalog);

	for (const repo of catalog.repos) {
		cloneOrSkipRepo(repo);
	}

	printWorkspaceSummary(catalog);
} catch (error) {
	console.error(error instanceof Error ? error.message : error);
	process.exit(1);
}