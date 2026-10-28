#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process"
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

export const extensionSource = "packages/automation/resources/browser-extension"
const submissionTagPrefix = "browser-extension-v"
const stableVersionPattern = /^\d+\.\d+\.\d+$/

const usage = () => {
  console.error("usage: scripts/release/browser-extension-submission.mjs <stable-version>")
  console.error()
  console.error(
    `Decides whether ${extensionSource} changed between the last submitted version and v<stable-version>.`
  )
  console.error(`Submitted versions are recorded as ${submissionTagPrefix}<version> tags.`)
}

export const submissionTag = (version) => `${submissionTagPrefix}${version}`

const compareVersions = (left, right) => {
  const leftParts = left.split(".").map(Number)
  const rightParts = right.split(".").map(Number)
  const difference = leftParts.map((part, index) => part - rightParts[index]).find(Boolean)
  return difference ?? 0
}

const submittedVersions = (tags) =>
  tags
    .filter((tag) => tag.startsWith(submissionTagPrefix))
    .map((tag) => tag.slice(submissionTagPrefix.length))
    .filter((version) => stableVersionPattern.test(version))

export const latestSubmissionBefore = (version, tags) =>
  submittedVersions(tags)
    .filter((submitted) => compareVersions(submitted, version) < 0)
    .toSorted(compareVersions)
    .at(-1)

export const decideSubmission = ({ version, tags, changedSince }) => {
  if (tags.includes(submissionTag(version))) {
    return { submit: false, reason: `${version} was already submitted.` }
  }

  const previous = latestSubmissionBefore(version, tags)
  if (previous === undefined) {
    return { submit: true, reason: "No earlier submission is recorded." }
  }
  if (changedSince(submissionTag(previous))) {
    return { submit: true, reason: `${extensionSource} changed since ${previous} was submitted.` }
  }
  return {
    submit: false,
    reason: `${extensionSource} is unchanged since ${previous} was submitted.`
  }
}

const repositoryTags = () =>
  execFileSync("git", ["tag", "--list", `${submissionTagPrefix}*`], { encoding: "utf8" })
    .split("\n")
    .filter(Boolean)

const sourceChangedBetween = (fromRef, toRef) => {
  const diff = spawnSync("git", ["diff", "--quiet", fromRef, toRef, "--", extensionSource], {
    stdio: "inherit"
  })
  if (diff.status === 0) return false
  if (diff.status === 1) return true
  throw new Error(`git diff ${fromRef} ${toRef} failed with status ${diff.status}`)
}

const writeOutput = (decision, environment) => {
  if (!environment.GITHUB_OUTPUT) return
  appendFileSync(environment.GITHUB_OUTPUT, `submit=${decision.submit}\n`)
}

export const main = (args = process.argv.slice(2), environment = process.env) => {
  if (args.includes("--help") || args.includes("-h")) {
    usage()
    return
  }
  if (args.length !== 1 || !stableVersionPattern.test(args[0])) {
    usage()
    throw new Error("Invalid arguments")
  }

  const [version] = args
  const decision = decideSubmission({
    version,
    tags: repositoryTags(),
    changedSince: (tag) => sourceChangedBetween(`${tag}^{commit}`, `v${version}^{commit}`)
  })
  console.log(`${decision.submit ? "Submitting" : "Skipping"} ${version}: ${decision.reason}`)
  writeOutput(decision, environment)
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main()
  } catch (error) {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 1
  }
}
