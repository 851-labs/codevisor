import { createHash, randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import {
  access,
  cp,
  lstat,
  mkdir,
  readFile,
  readlink,
  rename,
  rm,
  symlink,
  writeFile
} from "node:fs/promises"
import { createWriteStream } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join, relative } from "node:path"
import process from "node:process"
import { Readable } from "node:stream"
import { pipeline } from "node:stream/promises"
import { fileURLToPath } from "node:url"

const defaultOrigin = "https://updates.codevisor.dev/dev-artifacts/ghostty"
const frameworkRelativePath = join("apps", "macos", "Frameworks", "GhosttyKit.xcframework")

export async function ghosttyBuildStamp(repoRoot) {
  return (
    await capture(join(repoRoot, "apps/macos/scripts/build-ghostty.sh"), ["--print-stamp"], {
      cwd: repoRoot
    })
  ).trim()
}

export function ghosttyArtifactsRoot(environment = process.env) {
  return (
    environment.CODEVISOR_GHOSTTY_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "ghostty")
  )
}

export function ghosttyCachedFramework(artifactsRoot, stamp) {
  return join(artifactsRoot, stamp, "GhosttyKit.xcframework")
}

export async function ensureGhosttyFramework(repoRoot, environment = process.env) {
  const stamp = await ghosttyBuildStamp(repoRoot)
  const artifactsRoot = ghosttyArtifactsRoot(environment)
  const cachedFramework = ghosttyCachedFramework(artifactsRoot, stamp)
  const localFramework = join(repoRoot, frameworkRelativePath)

  if (!(await validFramework(cachedFramework, stamp))) {
    await withArtifactLock(artifactsRoot, stamp, async () => {
      if (await validFramework(cachedFramework, stamp)) return

      // One-time migration for checkouts created before the shared cache. This
      // checks only the current worktree and never searches sibling worktrees.
      if (await validRegularFramework(localFramework, stamp)) {
        console.log(`Installing the existing GhosttyKit into ${cachedFramework}`)
        await installFramework(localFramework, cachedFramework)
        return
      }

      await downloadFramework({ artifactsRoot, cachedFramework, environment, stamp })
    })
  }

  await linkLocalFramework(localFramework, cachedFramework, stamp)
  return { cachedFramework, localFramework, stamp }
}

export async function buildGhosttyFramework(repoRoot, environment = process.env) {
  await run("git", ["submodule", "update", "--init", ".repos/ghostty"], { cwd: repoRoot })
  await run(join(repoRoot, "apps/macos/scripts/build-ghostty.sh"), [], { cwd: repoRoot })
  const stamp = await ghosttyBuildStamp(repoRoot)
  const artifactsRoot = ghosttyArtifactsRoot(environment)
  const cachedFramework = ghosttyCachedFramework(artifactsRoot, stamp)
  const localFramework = join(repoRoot, frameworkRelativePath)
  if (!(await validRegularFramework(localFramework, stamp))) {
    throw new Error(`The Ghostty build did not produce a valid framework for ${stamp}`)
  }
  await withArtifactLock(artifactsRoot, stamp, () =>
    installFramework(localFramework, cachedFramework)
  )
  await linkLocalFramework(localFramework, cachedFramework, stamp)
  return { cachedFramework, localFramework, stamp }
}

async function downloadFramework({ artifactsRoot, cachedFramework, environment, stamp }) {
  const origin = (environment.CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN ?? defaultOrigin).replace(
    /\/+$/,
    ""
  )
  const archiveURL = `${origin}/${encodeURIComponent(stamp)}/GhosttyKit.xcframework.tar.gz`
  const checksumURL = `${archiveURL}.sha256`
  const temporaryRoot = join(artifactsRoot, `.download-${stamp}-${process.pid}-${randomUUID()}`)
  const archivePath = join(temporaryRoot, "GhosttyKit.xcframework.tar.gz")
  const extractedRoot = join(temporaryRoot, "extracted")

  console.log(`Downloading GhosttyKit ${stamp}`)
  await mkdir(extractedRoot, { recursive: true })
  try {
    const checksumResponse = await fetch(checksumURL)
    if (!checksumResponse.ok) {
      throw new Error(`checksum download returned ${checksumResponse.status}`)
    }
    const expectedChecksum = (await checksumResponse.text()).trim().match(/^[0-9a-fA-F]{64}/)?.[0]
    if (expectedChecksum === undefined) throw new Error("the published checksum is invalid")

    const archiveResponse = await fetch(archiveURL)
    if (!archiveResponse.ok || archiveResponse.body === null) {
      throw new Error(`artifact download returned ${archiveResponse.status}`)
    }
    await pipeline(Readable.fromWeb(archiveResponse.body), createWriteStream(archivePath))
    const actualChecksum = await sha256File(archivePath)
    if (actualChecksum.toLowerCase() !== expectedChecksum.toLowerCase()) {
      throw new Error(`checksum mismatch: expected ${expectedChecksum}, received ${actualChecksum}`)
    }

    await run("/usr/bin/tar", ["-xzf", archivePath, "-C", extractedRoot])
    const extractedFramework = join(extractedRoot, "GhosttyKit.xcframework")
    if (!(await validFramework(extractedFramework, stamp))) {
      throw new Error("the downloaded framework failed stamp or structure validation")
    }
    await installFramework(extractedFramework, cachedFramework)
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    throw new Error(
      `GhosttyKit ${stamp} is unavailable (${reason}). ` +
        "Run `bun run ghostty:build` only when intentionally rebuilding the shared artifact."
    )
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true })
  }
}

async function installFramework(source, destination) {
  const temporaryDestination = `${destination}.install-${process.pid}-${randomUUID()}`
  await mkdir(dirname(destination), { recursive: true })
  await rm(temporaryDestination, { recursive: true, force: true })
  try {
    await cp(source, temporaryDestination, { recursive: true })
    await rm(destination, { recursive: true, force: true })
    await rename(temporaryDestination, destination)
  } finally {
    await rm(temporaryDestination, { recursive: true, force: true })
  }
}

async function linkLocalFramework(localFramework, cachedFramework, expectedStamp) {
  try {
    const metadata = await lstat(localFramework)
    if (metadata.isSymbolicLink()) {
      if (await validFramework(localFramework, expectedStamp)) {
        const target = relative(dirname(localFramework), cachedFramework)
        const currentTarget = await readlink(localFramework)
        if (currentTarget === target) return
      }
    }
  } catch {
    // Missing or broken destination; create it below.
  }

  await mkdir(dirname(localFramework), { recursive: true })
  await rm(localFramework, { recursive: true, force: true })
  await symlink(relative(dirname(localFramework), cachedFramework), localFramework)
}

async function validRegularFramework(path, expectedStamp) {
  try {
    return (await lstat(path)).isDirectory() && (await validFramework(path, expectedStamp))
  } catch {
    return false
  }
}

export async function validFramework(path, expectedStamp) {
  try {
    const stamp = (await readFile(join(path, ".codevisor-stamp"), "utf8")).trim()
    if (stamp !== expectedStamp) return false
    await Promise.all([
      access(join(path, "Info.plist")),
      access(join(path, "macos-arm64_x86_64", "Headers", "ghostty.h")),
      access(join(path, "macos-arm64_x86_64", "ghostty-internal.a"))
    ])
    return true
  } catch {
    return false
  }
}

async function withArtifactLock(artifactsRoot, stamp, operation) {
  const lock = join(artifactsRoot, `.${stamp}.lock`)
  await mkdir(artifactsRoot, { recursive: true })
  for (let attempt = 0; attempt < 1_200; attempt += 1) {
    try {
      await mkdir(lock)
    } catch (cause) {
      if (cause?.code !== "EEXIST") throw cause
      await delay(250)
      continue
    }
    try {
      await writeFile(join(lock, "owner"), `${process.pid}\n`)
      return await operation()
    } finally {
      await rm(lock, { recursive: true, force: true })
    }
  }
  throw new Error(`Timed out waiting for the shared Ghostty artifact lock ${lock}`)
}

async function sha256File(path) {
  const hash = createHash("sha256")
  const { createReadStream } = await import("node:fs")
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest("hex")
}

function run(command, arguments_, options = {}) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    stdio: "inherit"
  })
  return waitForExit(child).then(({ code, signal }) => {
    if (code === 0) return
    throw new Error(
      `${basename(command)} failed (${signal === null ? `code ${code ?? 1}` : `signal ${signal}`})`
    )
  })
}

function capture(command, arguments_, options = {}) {
  const child = spawn(command, arguments_, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    stdio: ["ignore", "pipe", "inherit"]
  })
  let output = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    output += chunk
  })
  return waitForExit(child).then(({ code, signal }) => {
    if (code === 0) return output
    throw new Error(
      `${basename(command)} failed (${signal === null ? `code ${code ?? 1}` : `signal ${signal}`})`
    )
  })
}

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

async function main() {
  const repoRoot = fileURLToPath(new URL("..", import.meta.url))
  const command = process.argv[2] ?? "ensure"
  if (command === "ensure") {
    const result = await ensureGhosttyFramework(repoRoot)
    console.log(result.cachedFramework)
    return
  }
  if (command === "build") {
    const result = await buildGhosttyFramework(repoRoot)
    console.log(result.cachedFramework)
    return
  }
  if (command === "print-path") {
    const stamp = await ghosttyBuildStamp(repoRoot)
    console.log(ghosttyCachedFramework(ghosttyArtifactsRoot(), stamp))
    return
  }
  throw new Error(`Unknown command ${command}; expected ensure, build, or print-path`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 1
  })
}
