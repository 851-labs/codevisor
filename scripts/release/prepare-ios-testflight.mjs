import { execFileSync } from "node:child_process"
import { appendFile, mkdir, readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import { verifyAlphaProvenance } from "./ios-testflight-config.mjs"

const [runId, artifactDirectory] = process.argv.slice(2)
const repository = process.env.GITHUB_REPOSITORY
if (!/^[1-9]\d*$/.test(runId ?? "") || !artifactDirectory)
  throw new Error("Usage: prepare-ios-testflight.mjs ALPHA_RUN_ID ARTIFACT_DIRECTORY")
if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? ""))
  throw new Error("GITHUB_REPOSITORY must identify the source repository.")
const gh = (...args) => execFileSync("gh", args, { encoding: "utf8" })
const run = JSON.parse(gh("api", `repos/${repository}/actions/runs/${runId}`))
const directory = resolve(artifactDirectory)
await mkdir(directory, { recursive: true })
gh(
  "run",
  "download",
  runId,
  "--repo",
  repository,
  "--name",
  "codevisor-release-provenance",
  "--dir",
  directory
)
const provenance = JSON.parse(await readFile(join(directory, "release-provenance.json"), "utf8"))
const identity = verifyAlphaProvenance(run, provenance, repository, runId)
// The selected build can precede the workflow revision, but must be on main's history.
execFileSync("git", ["merge-base", "--is-ancestor", identity.source_sha, "HEAD"])
console.log(`Selected Alpha ${identity.version} (${identity.build}) from ${identity.source_sha}.`)
if (process.env.GITHUB_OUTPUT)
  await appendFile(
    process.env.GITHUB_OUTPUT,
    Object.entries(identity)
      .map(([key, value]) => `${key}=${value}\n`)
      .join("")
  )
