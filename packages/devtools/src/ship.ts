import { execFileSync, spawnSync, type SpawnSyncReturns } from "node:child_process"
import { setTimeout as sleep } from "node:timers/promises"
import { fileURLToPath } from "node:url"

import { isTransientGitHubError } from "./github-errors.ts"
import { nextWaitStep, type PullRequestFields, startOfWait } from "./merge-queue.ts"
import { createReporter } from "./reporter.ts"
import { parseShipArguments, type ShipOptions } from "./ship-arguments.ts"

const repoRoot = fileURLToPath(new URL("../../..", import.meta.url))
const reporter = createReporter()
const pollMilliseconds = 20_000
const ghAttempts = 4
const ghRetryMilliseconds = 5_000

const pullRequestStateQuery = `query($url: URI!) {
  resource(url: $url) {
    ... on PullRequest { state autoMergeRequest { enabledAt } mergeQueueEntry { state } }
  }
}`

class ShipError extends Error {}

async function main(): Promise<void> {
  const options = parseShipArguments(process.argv.slice(2))
  requireShippableBranch(git("rev-parse", "--abbrev-ref", "HEAD"))
  requireCleanTree()

  rebaseOntoMain()
  pushBranch()
  const pullRequest = openPullRequest(options)
  if (options.review) {
    reporter.done(`Opened ${pullRequest} for review; queue it with: gh pr merge --auto --squash`)
    return
  }

  queuePullRequest(pullRequest)
  if (!options.wait) {
    reporter.done(`Queued ${pullRequest}; it merges once CI passes in the merge queue`)
    return
  }

  await waitUntilLanded(pullRequest)
}

function requireShippableBranch(branch: string): void {
  if (branch === "HEAD")
    throw new ShipError("Ship from a branch, not a detached HEAD: git switch -c <name>")
  if (branch === "main") throw new ShipError("Ship from a branch, not main: git switch -c <name>")
}

function requireCleanTree(): void {
  if (git("status", "--porcelain") === "") return

  throw new ShipError("Commit or stash your changes first; ship only sends committed work")
}

function rebaseOntoMain(): void {
  reporter.step("Rebasing onto origin/main")
  git("fetch", "--quiet", "origin", "main")
  runVisible(
    "git",
    ["rebase", "--quiet", "origin/main"],
    "Rebase hit conflicts; resolve them, then ship again"
  )
}

function pushBranch(): void {
  reporter.step("Pushing (the pre-push hook runs the planned checks)")
  runVisible(
    "git",
    ["push", "--force-with-lease", "--set-upstream", "origin", "HEAD"],
    "Push failed"
  )
}

function openPullRequest(options: ShipOptions): string {
  const existing = gh(["pr", "view", "--json", "url", "--jq", ".url"])
  if (existing !== undefined) return existing

  reporter.step("Opening a pull request")
  const details = options.pullRequestDetails.length > 0 ? options.pullRequestDetails : ["--fill"]
  return (
    requiredGh(["pr", "create", "--base", "main", ...details])
      .split("\n")
      .at(-1) ?? ""
  )
}

function queuePullRequest(pullRequest: string): void {
  reporter.step("Queueing for merge")
  requiredGh(["pr", "merge", pullRequest, "--auto", "--squash"])
}

async function waitUntilLanded(pullRequest: string): Promise<void> {
  reporter.step("Waiting for the merge queue")
  let progress = startOfWait
  for (;;) {
    const step = nextWaitStep(progress, pullRequestFields(pullRequest))
    progress = step.progress
    if (step.verdict === "landed") return reporter.done(`Landed ${pullRequest}`)
    if (step.verdict === "left-queue") {
      throw new ShipError(
        `${pullRequest} left the merge queue; see its checks, fix, and ship again`
      )
    }
    if (step.verdict === "lost-contact")
      throw new ShipError("Lost contact with GitHub while waiting")

    await sleep(pollMilliseconds)
  }
}

function pullRequestFields(pullRequest: string): PullRequestFields | undefined {
  const response = gh([
    "api",
    "graphql",
    "-f",
    `query=${pullRequestStateQuery}`,
    "-F",
    `url=${pullRequest}`
  ])
  if (response === undefined) return undefined

  return JSON.parse(response).data.resource
}

function git(...args: Array<string>): string {
  return execFileSync("git", args, { cwd: repoRoot, encoding: "utf8" }).trim()
}

function runVisible(command: string, args: Array<string>, failure: string): void {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" })
  if (result.status !== 0) throw new ShipError(failure)
}

function gh(args: Array<string>): string | undefined {
  const result = ghWithRetries(args)
  return result.status === 0 ? result.stdout.trim() : undefined
}

function requiredGh(args: Array<string>): string {
  const result = ghWithRetries(args)
  if (result.status === 0) return result.stdout.trim()

  throw new ShipError(`gh ${args.join(" ")} failed: ${result.stderr.trim()}`)
}

function ghWithRetries(args: Array<string>): SpawnSyncReturns<string> {
  for (let attempt = 1; ; attempt += 1) {
    const result = spawnSync("gh", args, { cwd: repoRoot, encoding: "utf8" })
    if (result.status === 0 || attempt === ghAttempts || !isTransientGitHubError(result.stderr)) {
      return result
    }

    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ghRetryMilliseconds * attempt)
  }
}

try {
  await main()
} catch (error) {
  reporter.failure(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
