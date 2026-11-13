import { execFileSync, spawnSync, type SpawnSyncReturns } from "node:child_process"
import { setTimeout as sleep } from "node:timers/promises"
import { fileURLToPath } from "node:url"

import { isTransientGitHubError } from "./github-errors.ts"
import { createReporter } from "./reporter.ts"
import { parseShipArguments, type ShipOptions } from "./ship-arguments.ts"

const repoRoot = fileURLToPath(new URL("../../..", import.meta.url))
const reporter = createReporter()
const mergeabilityPollMilliseconds = 2_000
const mergeabilityPolls = 30
const ghAttempts = 4
const ghRetryMilliseconds = 5_000

class ShipError extends Error {}

async function main(): Promise<void> {
  const options = parseShipArguments(process.argv.slice(2))
  const branch = git("rev-parse", "--abbrev-ref", "HEAD")
  requireShippableBranch(branch)
  requireCleanTree()

  rebaseOntoMain()
  forgetDeletedBranches()
  pushBranch()
  const pullRequest = openPullRequest(branch, options)
  if (options.review) {
    reporter.done(`Opened ${pullRequest} for review; merge it with: gh pr merge --squash`)
    return
  }

  await mergePullRequest(pullRequest)
  moveOntoMergedMain()
  reporter.done(`Merged ${pullRequest}; Build checks it on main before the next Alpha`)
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

function forgetDeletedBranches(): void {
  git("remote", "prune", "origin")
}

function pushBranch(): void {
  reporter.step("Pushing (the pre-push hook runs the planned checks)")
  runVisible(
    "git",
    ["push", "--force-with-lease", "--set-upstream", "origin", "HEAD"],
    "Push failed"
  )
}

function openPullRequest(branch: string, options: ShipOptions): string {
  const existing = openPullRequestFor(branch)
  if (existing !== undefined) return existing

  reporter.step("Opening a pull request")
  const details = options.pullRequestDetails.length > 0 ? options.pullRequestDetails : ["--fill"]
  return (
    requiredGh(["pr", "create", "--base", "main", ...details])
      .split("\n")
      .at(-1) ?? ""
  )
}

function openPullRequestFor(branch: string): string | undefined {
  const url = requiredGh([
    "pr",
    "list",
    "--head",
    branch,
    "--base",
    "main",
    "--state",
    "open",
    "--json",
    "url",
    "--jq",
    ".[0].url // empty"
  ])
  return url === "" ? undefined : url
}

async function mergePullRequest(pullRequest: string): Promise<void> {
  reporter.step("Merging")
  await waitUntilMergeable(pullRequest)
  requiredGh(["pr", "merge", pullRequest, "--squash"])
}

function moveOntoMergedMain(): void {
  git("fetch", "--quiet", "origin", "main")
  git("reset", "--quiet", "--keep", "origin/main")
}

async function waitUntilMergeable(pullRequest: string): Promise<void> {
  for (let poll = 0; poll < mergeabilityPolls; poll += 1) {
    const mergeable = gh(["pr", "view", pullRequest, "--json", "mergeable", "--jq", ".mergeable"])
    if (mergeable === "MERGEABLE") return
    if (mergeable === "CONFLICTING")
      throw new ShipError(`${pullRequest} conflicts with main; ship again to rebase onto it`)

    await sleep(mergeabilityPollMilliseconds)
  }
  throw new ShipError(`GitHub never said whether ${pullRequest} can merge; ship again`)
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
