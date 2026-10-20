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

const pullRequestFields = "number,title,state,isDraft,url,statusCheckRollup,createdAt"
const noPullRequest = /no (?:open )?pull requests? found/i

export interface OwnedBranch {
  readonly name: string
  readonly ownedSince: string
}

export const parseGitPullRequest = (json: string): GitPullRequest | null =>
  pullRequestFrom(parseJson(json))

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
  knownBranch?: string,
  owned?: OwnedBranch
): Promise<GitPullRequest | null> => {
  const branch = knownBranch ?? (await gitCurrentBranch(dir, env))
  if (branch === null || branch.length === 0) return null
  return (await findGitPullRequest(dir, env, branch, owned)) ?? null
}

export const findGitPullRequest = async (
  dir: string,
  env: NodeJS.ProcessEnv,
  branch: string,
  owned?: OwnedBranch
): Promise<GitPullRequest | null | undefined> => {
  const result = await runGh(["pr", "view", branch, "--json", pullRequestFields], dir, env)
  if (!("stdout" in result)) return noPullRequest.test(result.failure) ? null : undefined

  const answer = parseJson(result.stdout)
  if (openedBefore(answer, ownedSince(branch, owned))) return null

  return pullRequestFrom(answer)
}

const ownedSince = (branch: string, owned: OwnedBranch | undefined): number | undefined =>
  owned?.name === branch ? Date.parse(owned.ownedSince) : undefined

const openedBefore = (answer: unknown, since: number | undefined): boolean =>
  since !== undefined && openedAt(answer) < since

const openedAt = (answer: unknown): number =>
  isRecord(answer) && typeof answer.createdAt === "string" ? Date.parse(answer.createdAt) : NaN

const parseJson = (json: string): unknown => {
  try {
    return JSON.parse(json)
  } catch {
    return null
  }
}

const pullRequestFrom = (value: unknown): GitPullRequest | null => {
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
