// Downloads and extracts one GitHub Actions artifact using the REST API. This
// keeps release jobs portable to self-hosted runners that do not have the
// GitHub CLI installed. Requires GH_TOKEN, GITHUB_API_URL, and
// GITHUB_REPOSITORY.
import { spawnSync } from "node:child_process"
import { accessSync, constants, createWriteStream } from "node:fs"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { join } from "node:path"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"

const usage = `usage: bun scripts/release/download-github-artifact.ts <run-id> <artifact-name> <destination> [wait-seconds]

Downloads and extracts one GitHub Actions artifact using the REST API. This
keeps release jobs portable to self-hosted runners that do not have the GitHub
CLI installed. Requires GH_TOKEN, GITHUB_API_URL, and GITHUB_REPOSITORY.`

interface GitHubArtifact {
  name: string
  expired: boolean
  archive_download_url?: string
}

interface GitHubArtifactPage {
  artifacts?: GitHubArtifact[]
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

// `command -v`: the extractor only has to be somewhere on PATH.
function commandExists(command: string): boolean {
  return (process.env.PATH ?? "").split(":").some((directory) => {
    try {
      accessSync(join(directory, command), constants.X_OK)
      return true
    } catch {
      return false
    }
  })
}

// set -e: a failing extractor aborts instead of leaving a partial destination.
function run(command: string, args: readonly string[]): void {
  const result = spawnSync(command, args, { stdio: "inherit" })
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}`)
}

// The shell version printed the usage block once if any of the three
// positional arguments was missing; the first miss here does the same.
function required(value: string | undefined): string {
  if (value) return value
  console.error(usage)
  process.exit(1)
}

const runId = required(process.argv[2])
const artifactName = required(process.argv[3])
const destination = required(process.argv[4])
const waitArgument = process.argv[5] || "0"
if (!/^\d+$/.test(waitArgument)) {
  console.error("wait-seconds must be a non-negative integer")
  process.exit(1)
}
const token = process.env.GH_TOKEN
const apiUrl = process.env.GITHUB_API_URL
const repository = process.env.GITHUB_REPOSITORY
if (!token || !apiUrl || !repository) {
  console.error("GH_TOKEN, GITHUB_API_URL, and GITHUB_REPOSITORY are required")
  process.exit(1)
}

const waitSeconds = Number(waitArgument)
const listing = `${apiUrl}/repos/${repository}/actions/runs/${runId}/artifacts?per_page=100`
const headers = {
  Authorization: `Bearer ${token}`,
  Accept: "application/vnd.github+json",
  "X-GitHub-Api-Version": "2022-11-28"
}

// curl --fail: any non-2xx listing response aborts the script.
async function findArchiveUrl(): Promise<string | undefined> {
  const response = await fetch(listing, { headers })
  if (!response.ok) {
    throw new Error(`Listing artifacts failed: ${response.status} ${response.statusText}`)
  }
  const page = (await response.json()) as GitHubArtifactPage
  const artifact = page.artifacts?.find((item) => item.name === artifactName && !item.expired)
  return artifact?.archive_download_url
}

async function main(): Promise<void> {
  const startedAt = Date.now()
  let archiveUrl: string | undefined
  while (true) {
    archiveUrl = await findArchiveUrl()
    if (archiveUrl) break
    // Whole seconds, like the shell's SECONDS: a wait of 0 gives up on the
    // very first miss rather than polling once more.
    if (Math.floor((Date.now() - startedAt) / 1000) >= waitSeconds) {
      console.error(
        `Artifact ${artifactName} was not available in run ${runId} after ${waitArgument}s.`
      )
      process.exit(1)
    }
    // Progress, deliberately on stdout as the shell version had it.
    console.log(`Artifact ${artifactName} is not ready; retrying in 10s.`)
    await delay(10_000)
  }

  // Stands in for mktemp plus `trap … EXIT`: the download lands in a private
  // directory that is removed however this script finishes.
  const scratch = await mkdtemp(join(process.env.RUNNER_TEMP || "/tmp", "codevisor-artifact."))
  try {
    const archive = join(scratch, "artifact.zip")
    // fetch follows the API's redirect to storage, as curl --location did.
    const response = await fetch(archiveUrl, { headers })
    if (!response.ok || !response.body) {
      throw new Error(
        `Downloading ${artifactName} failed: ${response.status} ${response.statusText}`
      )
    }
    await pipeline(Readable.fromWeb(response.body), createWriteStream(archive))
    await mkdir(destination, { recursive: true })
    if (commandExists("ditto")) {
      run("ditto", ["-x", "-k", archive, destination])
    } else if (commandExists("unzip")) {
      run("unzip", ["-q", archive, "-d", destination])
    } else {
      console.error("ditto or unzip is required to extract GitHub artifacts")
      // Not process.exit: the scratch directory still has to be cleaned up.
      process.exitCode = 1
      return
    }
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
  console.log(`Downloaded ${artifactName} from run ${runId} into ${destination}.`)
}

await main()
