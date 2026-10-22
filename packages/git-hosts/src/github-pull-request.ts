import { isRecord } from "@codevisor/api"
import type { GitPullRequest, GitPullRequestChecks, GitPullRequestState } from "@codevisor/api"

import { runCli } from "./cli-process.js"
import type { OwnedBranch } from "./git-host.js"

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

const pullRequestFields = "number,title,state,isDraft,url,statusCheckRollup,createdAt"
const noPullRequest = /no (?:open )?pull requests? found/i

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

export const parseGitPullRequest = (json: string): GitPullRequest | null =>
  pullRequestFrom(parseJson(json))

export const findGithubPullRequest = async (
  gh: string | undefined,
  directory: string,
  env: NodeJS.ProcessEnv,
  branch: string,
  owned?: OwnedBranch
): Promise<GitPullRequest | null | undefined> => {
  if (gh === undefined) return undefined

  const result = await viewPullRequest(gh, directory, env, branch)
  if (result.exitCode !== 0) return noPullRequest.test(result.stderr) ? null : undefined

  const answer = parseJson(result.stdout)
  if (openedBefore(answer, ownedSince(branch, owned))) return null

  return pullRequestFrom(answer)
}

const viewPullRequest = (gh: string, directory: string, env: NodeJS.ProcessEnv, branch: string) =>
  runCli(
    gh,
    ["pr", "view", branch, "--json", pullRequestFields],
    { ...env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" },
    { cwd: directory, timeoutMs: ghTimeoutMs }
  )

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
