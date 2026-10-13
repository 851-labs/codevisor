import { execFile } from "node:child_process"

import type { GitPullRequest, GitPullRequestChecks, GitPullRequestState } from "@codevisor/api"

import { runGit } from "./git.js"

/// `gh` talks to GitHub; a hung network call must not hold a request open.
const ghTimeoutMs = 15_000

const states: Readonly<Record<string, GitPullRequestState>> = {
  OPEN: "open",
  CLOSED: "closed",
  MERGED: "merged"
}

/// Check-run conclusions and commit-status states that mean a check failed.
const failedResults = new Set([
  "FAILURE",
  "ERROR",
  "TIMED_OUT",
  "CANCELLED",
  "ACTION_REQUIRED",
  "STARTUP_FAILURE"
])

/// Rolls `statusCheckRollup` up to one state. Its entries are check runs
/// (`status` until COMPLETED, then a `conclusion`) and commit statuses (a
/// `state`). Any failure wins; anything unfinished is pending.
export const rollUpChecks = (rollup: unknown): GitPullRequestChecks => {
  if (!Array.isArray(rollup) || rollup.length === 0) return "none"
  let pending = false
  for (const entry of rollup as ReadonlyArray<Record<string, unknown>>) {
    const result = entry.conclusion ?? entry.state
    if (typeof result === "string" && failedResults.has(result)) return "failing"
    const unfinished =
      entry.status !== undefined
        ? entry.status !== "COMPLETED"
        : entry.state === "PENDING" || entry.state === "EXPECTED"
    if (unfinished) pending = true
  }
  return pending ? "pending" : "passing"
}

/// `gh`'s output, or undefined when it fails for any reason: not installed,
/// signed out, not a GitHub remote, no pull request, or offline.
const gh = (
  args: ReadonlyArray<string>,
  cwd: string,
  env?: NodeJS.ProcessEnv
): Promise<string | undefined> =>
  new Promise((resolve) => {
    execFile(
      "gh",
      args,
      // Never block on an interactive prompt.
      {
        cwd,
        timeout: ghTimeoutMs,
        env: { ...(env ?? process.env), GH_PROMPT_DISABLED: "1", NO_COLOR: "1" }
      },
      (error, stdout) => resolve(error === null ? stdout : undefined)
    )
  })

/// Reads `gh pr view --json number,title,state,isDraft,url,statusCheckRollup`.
/// Null for anything that isn't a well-formed pull request.
export const parseGitPullRequest = (json: string): GitPullRequest | null => {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return null
  }
  if (typeof value !== "object" || value === null) return null
  const { number, title, state, isDraft, url, statusCheckRollup } = value as Record<string, unknown>
  const normalizedState = typeof state === "string" ? states[state] : undefined
  if (
    typeof number !== "number" ||
    typeof title !== "string" ||
    normalizedState === undefined ||
    typeof isDraft !== "boolean" ||
    typeof url !== "string"
  ) {
    return null
  }
  return {
    number,
    title,
    state: normalizedState,
    isDraft,
    url,
    checks: rollUpChecks(statusCheckRollup)
  }
}

/// The current branch's pull request, asked of the machine's own `gh` so it
/// uses whatever GitHub account the user signed in with there. Null when
/// HEAD is detached or `gh` can't answer; never throws.
export const gitPullRequest = async (
  dir: string,
  env?: NodeJS.ProcessEnv
): Promise<GitPullRequest | null> => {
  const branch = await runGit(
    "current-branch",
    ["symbolic-ref", "--short", "--quiet", "HEAD"],
    dir,
    env
  ).catch(() => null)
  if (branch === null || branch.length === 0) return null
  const output = await gh(
    ["pr", "view", branch, "--json", "number,title,state,isDraft,url,statusCheckRollup"],
    dir,
    env
  )
  return output === undefined ? null : parseGitPullRequest(output)
}
