#!/usr/bin/env bun

import {
	gitCapture,
	isGitRepo,
	loadCatalog,
	repoAbsolutePath,
} from "./lib/workspace-utils.ts";

const catalog = loadCatalog();

for (const repo of catalog.repos) {
	const targetPath = repoAbsolutePath(repo);
	console.log(`\n${repo.path} (${repo.id})`);

	if (!isGitRepo(targetPath)) {
		console.log("  not cloned yet — run `bun run workspace:setup`");
		continue;
	}

	const status = gitCapture(targetPath, ["status", "--short", "--branch"]) ?? "";
	for (const line of status.split("\n").filter(Boolean)) {
		console.log(`  ${line}`);
	}
}

console.log("");