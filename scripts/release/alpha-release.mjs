import { execFileSync } from "node:child_process"
import { appendFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export const BUILD_WORKFLOW = ".github/workflows/build.yml"
export const PROVENANCE_ARTIFACT = "codevisor-release-provenance"
export const PROVENANCE_ASSET = "release-provenance.json"
export const TESTFLIGHT_ASSET = "ios-testflight-build.json"
export const BUILD_NUMBER_OFFSET = 1000
const SERVER_TARGETS = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"]
const ALPHA_TAG = /^v(\d+\.\d+\.\d+)-alpha\.([1-9]\d*)$/

export function alphaBuildNumber(runNumber) {
  return Number(runNumber) + BUILD_NUMBER_OFFSET
}

export function alphaTag({ version, build }) {
  return `v${version}-alpha.${build}`
}

export function verifyAlphaProvenance(workflowRun, provenance, repository) {
  assertSuccessfulBuildRun(workflowRun, repository)
  const build = String(provenance.build_number ?? "")
  assertMatchingAlphaProvenance(workflowRun, provenance, build)
  const identity = {
    version: provenance.version,
    build,
    source_sha: provenance.source_sha,
    run_id: String(workflowRun.id),
    ghostty_stamp: provenance.ghostty_stamp
  }
  return { ...identity, tag: alphaTag(identity) }
}

function assertSuccessfulBuildRun(workflowRun, repository) {
  if (
    workflowRun.repository?.full_name !== repository ||
    workflowRun.head_repository?.full_name !== repository ||
    workflowRun.path !== BUILD_WORKFLOW ||
    workflowRun.head_branch !== "main" ||
    !["push", "workflow_dispatch"].includes(workflowRun.event) ||
    workflowRun.status !== "completed" ||
    workflowRun.conclusion !== "success"
  )
    throw new Error(
      `Run ${workflowRun.id} is not a successful Build run on this repository's main.`
    )
}

function assertMatchingAlphaProvenance(workflowRun, provenance, build) {
  if (
    provenance.channel !== "alpha" ||
    !/^\d+\.\d+\.\d+$/.test(provenance.version ?? "") ||
    !/^[1-9]\d*$/.test(build) ||
    build !== String(alphaBuildNumber(workflowRun.run_number)) ||
    String(provenance.run_id) !== String(workflowRun.id) ||
    !/^[0-9a-f]{40}$/.test(provenance.source_sha ?? "") ||
    provenance.source_sha !== workflowRun.head_sha ||
    !/^[0-9a-f]{40}-[0-9a-f]{16}$/.test(provenance.ghostty_stamp ?? "")
  )
    throw new Error(`The provenance of run ${workflowRun.id} does not match the run.`)
}

export function releaseAssetNames({ ghostty_stamp }) {
  const files = [
    "Codevisor-macOS-arm64.zip",
    "Codevisor-arm64.dmg",
    ...SERVER_TARGETS.map((target) => `codevisor-server-${target}.tar.gz`),
    `GhosttyKit-${ghostty_stamp}.tar.gz`
  ]
  return [...files.flatMap((file) => [file, `${file}.sha256`]), PROVENANCE_ASSET]
}

export function isPublishedRelease(release, identity) {
  if (!release || release.isDraft || !release.isPrerelease) return false
  const names = new Set(release.assets.map((asset) => asset.name))
  return releaseAssetNames(identity).every((name) => names.has(name))
}

export function pendingPublication(release, identity) {
  const macos = !isPublishedRelease(release, identity)
  const ios = macos || !release.assets.some((asset) => asset.name === TESTFLIGHT_ASSET)
  return { macos, ios }
}

export function parseRemoteTags(output) {
  const tags = new Map()
  for (const line of output.split("\n").filter(Boolean)) {
    const [sha, ref] = line.split("\t")
    const peeled = ref.endsWith("^{}")
    const name = ref.replace(/^refs\/tags\//, "").replace(/\^\{\}$/, "")
    if (peeled || !tags.has(name)) tags.set(name, sha)
  }
  return tags
}

export function newestAlphaTag(tags) {
  const builds = tags
    .map((tag) => ALPHA_TAG.exec(tag))
    .filter(Boolean)
    .toSorted((a, b) => Number(b[2]) - Number(a[2]))
  return builds[0]?.[0]
}

function run(command, args, options = {}) {
  return execFileSync(command, args, { encoding: "utf8", ...options }).trim()
}

function succeeds(command, args) {
  try {
    execFileSync(command, args, { stdio: "ignore" })
    return true
  } catch {
    return false
  }
}

function releaseView(tag) {
  try {
    return JSON.parse(run("gh", ["release", "view", tag, "--json", "isDraft,isPrerelease,assets"]))
  } catch {
    return undefined
  }
}

async function readProvenance(directory) {
  return JSON.parse(await readFile(join(directory, PROVENANCE_ASSET), "utf8"))
}

function verifiedIdentity(repository, runId, provenance) {
  const workflowRun = JSON.parse(run("gh", ["api", `repos/${repository}/actions/runs/${runId}`]))
  const identity = verifyAlphaProvenance(workflowRun, provenance, repository)
  if (!succeeds("git", ["merge-base", "--is-ancestor", identity.source_sha, "HEAD"]))
    throw new Error(`${identity.source_sha} is not on main.`)
  return identity
}

async function writeOutputs(values) {
  const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`)
  console.log(lines.join("\n"))
  if (process.env.GITHUB_OUTPUT)
    await appendFile(process.env.GITHUB_OUTPUT, `${lines.join("\n")}\n`)
}

async function summarize(message) {
  console.log(message)
  if (process.env.GITHUB_STEP_SUMMARY)
    await appendFile(process.env.GITHUB_STEP_SUMMARY, `${message}\n`)
}

function downloadAlphaProvenance(publishedTag, runId, directory) {
  if (
    publishedTag &&
    succeeds("gh", [
      "release",
      "download",
      publishedTag,
      "--pattern",
      PROVENANCE_ASSET,
      "--dir",
      directory
    ])
  )
    return true
  return succeeds("gh", [
    "run",
    "download",
    runId,
    "--name",
    PROVENANCE_ARTIFACT,
    "--dir",
    directory
  ])
}

function assertAlphaTagIdentity(tags, identity) {
  const tagCommit = tags.get(identity.tag)
  if (tagCommit && tagCommit !== identity.source_sha)
    throw new Error(`${identity.tag} points to ${tagCommit}, not ${identity.source_sha}.`)
}

async function next(repository) {
  const [latest] = JSON.parse(
    run("gh", [
      "api",
      `repos/${repository}/actions/workflows/build.yml/runs?branch=main&status=success&per_page=1`
    ])
  ).workflow_runs
  const nothing = { publish_macos: false, publish_ios: false }
  if (!latest) {
    await summarize("No successful Build run on main yet.")
    return writeOutputs(nothing)
  }
  const runId = String(latest.id)
  const build = String(alphaBuildNumber(latest.run_number))
  const tags = parseRemoteTags(run("git", ["ls-remote", "--tags", "origin"]))
  const publishedTag = [...tags.keys()].find((name) => ALPHA_TAG.exec(name)?.[2] === build)
  const directory = await mkdtemp(join(tmpdir(), "codevisor-alpha-"))
  try {
    const found = downloadAlphaProvenance(publishedTag, runId, directory)
    if (!found) {
      await summarize(`Build run ${runId} was never published and its artifacts expired.`)
      return writeOutputs(nothing)
    }
    const identity = verifiedIdentity(repository, runId, await readProvenance(directory))
    if (tags.has(`v${identity.version}`)) {
      await summarize(`Stable v${identity.version} exists; Alpha ${identity.tag} is not published.`)
      return writeOutputs(nothing)
    }
    assertAlphaTagIdentity(tags, identity)
    const pending = pendingPublication(releaseView(identity.tag), identity)
    if (!pending.macos && !pending.ios) {
      await summarize(`Newest Alpha ${identity.tag} is already published.`)
      return writeOutputs(nothing)
    }
    const parts = [pending.macos && "macOS and server release", pending.ios && "TestFlight upload"]
    await summarize(
      `Alpha ${identity.tag} (run ${runId}) needs: ${parts.filter(Boolean).join(", ")}.`
    )
    return writeOutputs({ publish_macos: pending.macos, publish_ios: pending.ios, ...identity })
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

async function verify(repository, target, outputDirectory) {
  const tag = target.commit
    ? newestAlphaTag(
        run("git", ["tag", "--points-at", target.commit, "--list", "v*-alpha.*"]).split("\n")
      )
    : target.tag
  if (!tag || !ALPHA_TAG.test(tag))
    throw new Error(
      `No Alpha tag ${target.commit ? `points at ${target.commit}` : `named ${tag}`}.`
    )
  const directory = resolve(outputDirectory ?? (await mkdtemp(join(tmpdir(), "codevisor-alpha-"))))
  await mkdir(directory, { recursive: true })
  if (
    !succeeds("gh", [
      "release",
      "download",
      tag,
      "--pattern",
      PROVENANCE_ASSET,
      "--dir",
      directory,
      "--clobber"
    ])
  )
    throw new Error(`${tag} has no published release with ${PROVENANCE_ASSET}.`)
  const provenance = await readProvenance(directory)
  const identity = verifiedIdentity(repository, provenance.run_id, provenance)
  if (identity.tag !== tag) throw new Error(`${tag} holds the provenance of ${identity.tag}.`)
  const tagCommit = run("git", ["rev-parse", `refs/tags/${tag}^{commit}`])
  if (tagCommit !== identity.source_sha)
    throw new Error(`${tag} points to ${tagCommit}, not ${identity.source_sha}.`)
  if (!isPublishedRelease(releaseView(tag), identity))
    throw new Error(`Alpha ${tag} is not a complete published prerelease.`)
  if (!outputDirectory) await rm(directory, { recursive: true, force: true })
  return writeOutputs(identity)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const repository = process.env.GITHUB_REPOSITORY
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? ""))
    throw new Error("GITHUB_REPOSITORY must identify the repository.")
  const [command, ...args] = process.argv.slice(2)
  if (command === "build-number" && /^[1-9]\d*$/.test(args[0] ?? ""))
    console.log(alphaBuildNumber(args[0]))
  else if (command === "next") await next(repository)
  else if (command === "verify" && args[0] === "--commit" && args[1])
    await verify(repository, { commit: args[1] }, args[2])
  else if (command === "verify" && args[0]) await verify(repository, { tag: args[0] }, args[1])
  else
    throw new Error(
      "Usage: alpha-release.mjs build-number <run> | next | verify <alpha-tag | --commit SHA> [directory]"
    )
}
