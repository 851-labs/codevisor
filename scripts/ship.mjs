#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process"
import { setTimeout as sleep } from "node:timers/promises"
import { fileURLToPath } from "node:url"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const pollMilliseconds = 20_000
const unreachablePollsAllowed = 15
const usage =
  "usage: bun run ship [--review] [--wait] [--title <title>] [--body <body> | --body-file <path>]"

async function main() {
  const options = parseShipArguments(process.argv.slice(2))
  const branch = currentBranch()
  requireShippableBranch(branch)
  requireCleanTree()

  rebaseOntoMain()
  pushBranch()
  const pullRequest = openPullRequest(options)
  if (options.review)
    return report(`Opened ${pullRequest} for review; queue it with: gh pr merge --auto --squash`)

  queuePullRequest(pullRequest)
  if (!options.wait)
    return report(`Queued ${pullRequest}; it merges once CI passes in the merge queue`)

  await waitUntilLanded(pullRequest)
}

function parseShipArguments(argv) {
  const options = { review: false, wait: false, prArguments: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "--review") options.review = true
    else if (argument === "--wait") options.wait = true
    else if (["--title", "--body", "--body-file"].includes(argument) && index + 1 < argv.length) {
      options.prArguments.push(argument, argv[(index += 1)])
    } else fail(`${usage} (unknown argument ${argument})`)
  }
  return options
}

function currentBranch() {
  return git("rev-parse", "--abbrev-ref", "HEAD")
}

function requireShippableBranch(branch) {
  if (branch === "HEAD") fail("Ship from a branch, not a detached HEAD: git switch -c <name>")
  if (branch === "main") fail("Ship from a branch, not main: git switch -c <name>")
}

function requireCleanTree() {
  if (git("status", "--porcelain") === "") return

  fail("Commit or stash your changes first; ship only sends committed work")
}

function rebaseOntoMain() {
  step("Rebasing onto origin/main")
  git("fetch", "--quiet", "origin", "main")
  run(
    "git",
    ["rebase", "--quiet", "origin/main"],
    "Rebase hit conflicts; resolve them, then ship again"
  )
}

function pushBranch() {
  step("Pushing (the pre-push hook runs the planned checks)")
  run("git", ["push", "--force-with-lease", "--set-upstream", "origin", "HEAD"], "Push failed")
}

function openPullRequest(options) {
  const existing = gh(["pr", "view", "--json", "url", "--jq", ".url"], { allowFailure: true })
  if (existing !== undefined) return existing

  step("Opening a pull request")
  const details = options.prArguments.length > 0 ? options.prArguments : ["--fill"]
  return gh(["pr", "create", "--base", "main", ...details])
    .split("\n")
    .at(-1)
}

function queuePullRequest(pullRequest) {
  step("Queueing for merge")
  gh(["pr", "merge", pullRequest, "--auto", "--squash"])
}

async function waitUntilLanded(pullRequest) {
  step("Waiting for the merge queue")
  let unreachablePolls = 0
  for (;;) {
    const state = pullRequestState(pullRequest)
    unreachablePolls = state === undefined ? unreachablePolls + 1 : 0
    if (unreachablePolls > unreachablePollsAllowed) fail("Lost contact with GitHub while waiting")
    if (state?.merged) return report(`Landed ${pullRequest}`)
    if (state?.leftQueue)
      fail(`${pullRequest} left the merge queue; see its checks, fix, and ship again`)

    await sleep(pollMilliseconds)
  }
}

const pullRequestStateQuery = `query($url: URI!) {
  resource(url: $url) {
    ... on PullRequest { state autoMergeRequest { enabledAt } mergeQueueEntry { state } }
  }
}`

function pullRequestState(pullRequest) {
  const response = gh(
    ["api", "graphql", "-f", `query=${pullRequestStateQuery}`, "-F", `url=${pullRequest}`],
    { allowFailure: true }
  )
  if (response === undefined) return undefined

  const fields = JSON.parse(response).data.resource
  return {
    merged: fields.state === "MERGED",
    leftQueue: fields.state === "OPEN" && !isWaitingToMerge(fields)
  }
}

function isWaitingToMerge(fields) {
  return fields.autoMergeRequest !== null || fields.mergeQueueEntry !== null
}

function git(...args) {
  return execFileSync("git", args, { cwd: repoRoot, encoding: "utf8" }).trim()
}

function gh(args, { allowFailure = false } = {}) {
  const result = spawnSync("gh", args, { cwd: repoRoot, encoding: "utf8" })
  if (result.status === 0) return result.stdout.trim()
  if (allowFailure) return undefined

  return fail(`gh ${args.join(" ")} failed: ${result.stderr.trim()}`)
}

function run(command, args, failure) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" })
  if (result.status !== 0) fail(failure)
}

function step(message) {
  console.error(`▸ ${message}`)
}

function report(message) {
  console.error(`✓ ${message}`)
}

function fail(message) {
  console.error(`✗ ${message}`)
  process.exit(1)
}

await main()
