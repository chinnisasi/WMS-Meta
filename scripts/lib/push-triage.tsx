// Interactive push triage (Ink). Shown only when stdin+stdout are TTYs and at
// least one repo has a real choice to make; every other run falls back to the
// plain non-interactive output. The UI only decides — it never runs git itself.
// The caller applies the returned decisions after the UI has unmounted.

import { useState } from "react";
import { Box, Text, useInput, render } from "ink";
import type { GitRepoState } from "./workspace-utils.ts";

export type PushDecision = "skip" | "push" | "push-upstream";

export interface RepoReview {
	id: string;
	path: string;
	absolutePath: string;
	state: GitRepoState;
	branch: string | null;
	ahead: number;
	behind: number;
	dirtyCount: number;
	untrackedCount: number;
	/** `git log --oneline @{u}..` — one line per unpushed commit. */
	unpushedCommits: string[];
	/** `git status --short` lines, for the detail view. */
	statusLines: string[];
	/** True when `git fetch` failed — ahead/behind may be based on stale refs. */
	fetchFailed: boolean;
	/** Decisions the user may cycle through, in ←/→ order. */
	options: PushDecision[];
	defaultDecision: PushDecision;
	/** Human explanation of why the choices are limited (or null). */
	note: string | null;
	/** Commands to run by hand when this repo needs manual attention. */
	advice: string[];
}

const DECISION_LABELS: Record<PushDecision, string> = {
	skip: "skip",
	push: "push",
	"push-upstream": "push -u origin",
};

/** One shared state label for both the Ink UI and plain output, so the two
 *  cannot drift. Null branch renders as "?" everywhere. */
export function stateNote(review: RepoReview): string {
	const dirty = review.dirtyCount > 0 ? `, ${review.dirtyCount} uncommitted` : "";
	const untracked = review.untrackedCount > 0 ? `, ${review.untrackedCount} untracked` : "";
	const branch = review.branch ?? "?";
	switch (review.state) {
		case "in-sync":
			return `[${branch}: in sync${dirty}${untracked}]`;
		case "ahead":
			return `[${branch}: ahead ${review.ahead}${dirty}${untracked}]`;
		case "behind":
		case "diverged":
			return `[${branch}: ahead ${review.ahead} / behind ${review.behind} (${review.state})${dirty}${untracked}]`;
		case "no-upstream":
			return `[${branch}: no upstream${dirty}${untracked}]`;
		case "no-commits":
			return `[${branch}: no commits yet${dirty}${untracked}]`;
		case "not-a-repo":
			return "[not a git repo]";
		case "git-error":
			return "[git status failed]";
		case "detached":
			return "[detached HEAD]";
		case "upstream-gone":
			return `[${branch}: upstream deleted on remote${dirty}${untracked}]`;
	}
}

export function Details({ review }: { review: RepoReview }) {
	const MAX_LINES = 10;
	if (review.state === "not-a-repo" || review.state === "git-error") {
		return (
			<Text dimColor>      no details available for this repo</Text>
		);
	}
	return (
		<Box flexDirection="column" marginLeft={4}>
			{review.unpushedCommits.length > 0 ? (
				<>
					<Text dimColor>      unpushed commits:</Text>
					{review.unpushedCommits.slice(0, MAX_LINES).map((line) => (
						<Text key={line} dimColor>
							        {line}
						</Text>
					))}
					{review.unpushedCommits.length > MAX_LINES && (
						<Text dimColor>        … and {review.unpushedCommits.length - MAX_LINES} more</Text>
					)}
				</>
			) : (
				<Text dimColor>      no unpushed commits</Text>
			)}
			{review.statusLines.length > 0 && (
				<Text dimColor>      working tree: {review.statusLines.slice(0, MAX_LINES).join(" · ")}</Text>
			)}
			{review.advice.length > 0 && (
				<Text dimColor>      manual fix: {review.advice.join("  ")}</Text>
			)}
		</Box>
	);
}

function TriageApp({
	reviews,
	onDone,
}: {
	reviews: RepoReview[];
	onDone: (decisions: Record<string, PushDecision>) => void;
}) {
	const [index, setIndex] = useState(0);
	const [showDetails, setShowDetails] = useState(false);
	const [decisions, setDecisions] = useState<Record<string, PushDecision>>(() =>
		Object.fromEntries(reviews.map((review) => [review.id, review.defaultDecision])),
	);

	useInput((input, key) => {
		if (key.upArrow || input === "k") {
			setIndex((i) => Math.max(0, i - 1));
		} else if (key.downArrow || input === "j") {
			setIndex((i) => Math.min(reviews.length - 1, i + 1));
		} else if (key.leftArrow || key.rightArrow) {
			const review = reviews[index];
			if (review.options.length < 2) return;
			const position = review.options.indexOf(decisions[review.id]);
			const step = key.rightArrow ? 1 : -1;
			const next = review.options[(position + step + review.options.length) % review.options.length];
			setDecisions((current) => ({ ...current, [review.id]: next }));
		} else if (input === "v") {
			setShowDetails((shown) => !shown);
		} else if (key.ctrl && input === "c") {
			// Handled here because exitOnCtrlC is off: Ctrl+C quits with defaults
			// instead of leaving the caller's promise unresolved.
			onDone(Object.fromEntries(reviews.map((review) => [review.id, review.defaultDecision])));
		} else if (key.return) {
			onDone(decisions);
		} else if (input === "q") {
			// Quit without changing anything: every repo keeps its default action.
			onDone(Object.fromEntries(reviews.map((review) => [review.id, review.defaultDecision])));
		}
	});

	return (
		<Box flexDirection="column" paddingY={1}>
			<Text bold>Review repos before pushing</Text>
			<Text dimColor>
				↑/↓ move · ←/→ change action · v details · enter continue · q keep defaults
			</Text>
			{reviews.map((review, i) => (
				<Box key={review.id} flexDirection="column">
					<Box>
						<Text color={i === index ? "cyan" : undefined}>{i === index ? "❯ " : "  "}</Text>
						<Text bold={i === index}>{review.id}</Text>
						<Text>  </Text>
						<Text dimColor>{stateNote(review)}</Text>
						<Text>  →  </Text>
						<Text
							color={
								decisions[review.id] === review.defaultDecision ? undefined : "green"
							}
						>
							{DECISION_LABELS[decisions[review.id]]}
						</Text>
					</Box>
					{i === index && review.fetchFailed && (
						<Text color="yellow">      ⚠ git fetch failed (offline?) — ahead/behind may be stale</Text>
					)}
					{i === index && review.note !== null && (
						<Text dimColor>      {review.note}</Text>
					)}
					{i === index && showDetails && <Details review={review} />}
				</Box>
			))}
			<Text dimColor>press enter to push the repos marked as such</Text>
		</Box>
	);
}

/** Renders the triage UI and resolves with the user's decisions once it closes.
 *  The app is unmounted on resolve, otherwise Ink keeps the process alive with
 *  the frozen screen on it. */
export function runPushTriage(
	reviews: RepoReview[],
): Promise<Record<string, PushDecision>> {
	return new Promise((resolve) => {
		const instance = render(
			<TriageApp
				reviews={reviews}
				onDone={(decisions) => {
					instance.unmount();
					resolve(decisions);
				}}
			/>,
			// Ink's default Ctrl+C behavior unmounts without calling our callback,
			// which would leave the caller's promise hanging — so it is off, and
			// the Ctrl+C key is handled in TriageApp instead (quit with defaults).
			{ exitOnCtrlC: false },
		);
	});
}