import { execFile } from "node:child_process"

import { isRecord } from "@codevisor/api"
import type { GitPullRequest, GitPullRequestChecks, GitPullRequestState } from "@codevisor/api"

import { runGit } from "./git.js"

const ghTimeoutMs = 15_000

const states: Readonly<Record<string, GitPullRequestState>> = {
  OPEN: "open",
  CLOSED: "closed",
  MERGED: "merged"
}

const failedResults = new Set([
  "FAILURE",
  "ERROR",
  "TIMED_OUT",
  "CANCELLED",
  "ACTION_REQUIRED",
  "STARTUP_FAILURE"
])

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

type GhResult = { readonly stdout: string } | { readonly failure: string }

const runGh = (
  args: ReadonlyArray<string>,
  cwd: string,
  env: NodeJS.ProcessEnv
): Promise<GhResult> =>
  new Promise((resolve) => {
    execFile(
      "gh",
      args,
      {
        cwd,
        timeout: ghTimeoutMs,
        env: { ...env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" }
      },
      (error, stdout, stderr) => resolve(error === null ? { stdout } : { failure: stderr })
    )
  })

const pullRequestFields = "number,title,state,isDraft,url,statusCheckRollup"
const noPullRequest = /no (?:open )?pull requests? found/i

export const parseGitPullRequest = (json: string): GitPullRequest | null => {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return null
  }
  if (!isRecord(value)) return null
  const { number, title, state, isDraft, url, statusCheckRollup } = value
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

export const gitCurrentBranch = async (
  dir: string,
  env: NodeJS.ProcessEnv
): Promise<string | null> => {
  const branch = await runGit(
    "current-branch",
    ["symbolic-ref", "--short", "--quiet", "HEAD"],
    dir,
    env
  ).catch(() => null)
  return branch === null || branch.length === 0 ? null : branch
}

export const gitPullRequest = async (
  dir: string,
  env: NodeJS.ProcessEnv,
  knownBranch?: string
): Promise<GitPullRequest | null> => {
  const branch = knownBranch ?? (await gitCurrentBranch(dir, env))
  if (branch === null || branch.length === 0) return null
  return (await findGitPullRequest(dir, env, branch)) ?? null
}

export const findGitPullRequest = async (
  dir: string,
  env: NodeJS.ProcessEnv,
  branch: string
): Promise<GitPullRequest | null | undefined> => {
  const result = await runGh(["pr", "view", branch, "--json", pullRequestFields], dir, env)
  if ("stdout" in result) return parseGitPullRequest(result.stdout)
  return noPullRequest.test(result.failure) ? null : undefined
}
