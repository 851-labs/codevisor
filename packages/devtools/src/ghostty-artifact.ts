import { createHash, randomUUID } from "node:crypto"
import { createReadStream, createWriteStream } from "node:fs"
import { access, cp, lstat, mkdir, readFile, readlink, rename, rm, symlink } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join, relative } from "node:path"
import { pipeline } from "node:stream/promises"

import { withArtifactLock } from "./artifact-lock.ts"
import { captureCommand, runCommand } from "./commands.ts"

type Environment = Readonly<Record<string, string | undefined>>

export interface GhosttyFramework {
  readonly cachedFramework: string
  readonly localFramework: string
  readonly stamp: string
}

const defaultOrigin = "https://updates.codevisor.dev/dev-artifacts/ghostty"
const frameworkRelativePath = join("apps", "macos", "Frameworks", "GhosttyKit.xcframework")
export const GHOSTTY_SLICES = ["macos-arm64_x86_64", "ios-arm64", "ios-arm64_x86_64-simulator"]

export const ghosttyBuildScript = (repoRoot: string): string =>
  join(repoRoot, "apps/macos/scripts/build-ghostty.sh")

export async function ghosttyBuildStamp(repoRoot: string): Promise<string> {
  return (
    await captureCommand(ghosttyBuildScript(repoRoot), ["--print-stamp"], { cwd: repoRoot })
  ).trim()
}

export function ghosttyArtifactsRoot(environment: Environment = process.env): string {
  return (
    environment.CODEVISOR_GHOSTTY_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "ghostty")
  )
}

export function ghosttyCachedFramework(artifactsRoot: string, stamp: string): string {
  return join(artifactsRoot, stamp, "GhosttyKit.xcframework")
}

export async function ensureGhosttyFramework(
  repoRoot: string,
  environment: Environment = process.env
): Promise<GhosttyFramework> {
  const stamp = await ghosttyBuildStamp(repoRoot)
  const artifactsRoot = ghosttyArtifactsRoot(environment)
  const cachedFramework = ghosttyCachedFramework(artifactsRoot, stamp)
  const localFramework = join(repoRoot, frameworkRelativePath)

  if (!(await validFramework(cachedFramework, stamp))) {
    await withArtifactLock(stampLock(artifactsRoot, stamp), async () => {
      if (await validFramework(cachedFramework, stamp)) return
      if (await validRegularFramework(localFramework, stamp)) {
        console.log(`Installing the existing GhosttyKit into ${cachedFramework}`)
        await installFramework(localFramework, cachedFramework)
        return
      }

      try {
        await downloadFramework({ artifactsRoot, cachedFramework, environment, stamp })
      } catch (cause) {
        console.log(
          `GhosttyKit ${stamp} is not published yet (${messageOf(cause)}); building it locally.`
        )
        await run(ghosttyBuildScript(repoRoot), [], repoRoot)
        if (!(await validRegularFramework(localFramework, stamp))) {
          throw new Error(
            `The local Ghostty build did not produce a valid framework for ${stamp}`,
            { cause }
          )
        }
        await installFramework(localFramework, cachedFramework)
      }
    })
  }

  await linkLocalFramework(localFramework, cachedFramework, stamp)
  return { cachedFramework, localFramework, stamp }
}

export async function buildGhosttyFramework(
  repoRoot: string,
  environment: Environment = process.env
): Promise<GhosttyFramework> {
  await run(ghosttyBuildScript(repoRoot), [], repoRoot)
  const stamp = await ghosttyBuildStamp(repoRoot)
  const artifactsRoot = ghosttyArtifactsRoot(environment)
  const cachedFramework = ghosttyCachedFramework(artifactsRoot, stamp)
  const localFramework = join(repoRoot, frameworkRelativePath)
  if (!(await validRegularFramework(localFramework, stamp))) {
    throw new Error(`The Ghostty build did not produce a valid framework for ${stamp}`)
  }
  await withArtifactLock(stampLock(artifactsRoot, stamp), () =>
    installFramework(localFramework, cachedFramework)
  )
  await linkLocalFramework(localFramework, cachedFramework, stamp)
  return { cachedFramework, localFramework, stamp }
}

export async function validFramework(path: string, expectedStamp: string): Promise<boolean> {
  try {
    const stamp = (await readFile(join(path, ".codevisor-stamp"), "utf8")).trim()
    if (stamp !== expectedStamp) return false

    await Promise.all([
      access(join(path, "Info.plist")),
      ...GHOSTTY_SLICES.flatMap((slice) => [
        access(join(path, slice, "Headers", "GhosttyKit", "ghostty.h")),
        access(join(path, slice, "Headers", "GhosttyKit", "module.modulemap")),
        access(join(path, slice, "ghostty-internal.a"))
      ])
    ])
    return true
  } catch {
    return false
  }
}

async function downloadFramework(options: {
  readonly artifactsRoot: string
  readonly cachedFramework: string
  readonly environment: Environment
  readonly stamp: string
}): Promise<void> {
  const { artifactsRoot, cachedFramework, environment, stamp } = options
  const origin = (environment.CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN ?? defaultOrigin).replace(
    /\/+$/,
    ""
  )
  const archiveURL = `${origin}/${encodeURIComponent(stamp)}/GhosttyKit.xcframework.tar.gz`
  const temporaryRoot = join(artifactsRoot, `.download-${stamp}-${process.pid}-${randomUUID()}`)
  const archivePath = join(temporaryRoot, "GhosttyKit.xcframework.tar.gz")
  const extractedRoot = join(temporaryRoot, "extracted")

  console.log(`Downloading GhosttyKit ${stamp}`)
  await mkdir(extractedRoot, { recursive: true })
  try {
    const checksumResponse = await fetch(`${archiveURL}.sha256`)
    if (!checksumResponse.ok)
      throw new Error(`checksum download returned ${checksumResponse.status}`)
    const expectedChecksum = /^[0-9a-fA-F]{64}/.exec((await checksumResponse.text()).trim())?.[0]
    if (expectedChecksum === undefined) throw new Error("the published checksum is invalid")

    const archiveResponse = await fetch(archiveURL)
    if (!archiveResponse.ok || archiveResponse.body === null)
      throw new Error(`artifact download returned ${archiveResponse.status}`)
    await pipeline(archiveResponse.body, createWriteStream(archivePath))
    const actualChecksum = await sha256File(archivePath)
    if (actualChecksum.toLowerCase() !== expectedChecksum.toLowerCase()) {
      throw new Error(`checksum mismatch: expected ${expectedChecksum}, received ${actualChecksum}`)
    }

    await run("/usr/bin/tar", ["-xzf", archivePath, "-C", extractedRoot])
    const extractedFramework = join(extractedRoot, "GhosttyKit.xcframework")
    if (!(await validFramework(extractedFramework, stamp)))
      throw new Error("the downloaded framework failed stamp or structure validation")
    await installFramework(extractedFramework, cachedFramework)
  } catch (cause) {
    throw new Error(
      `GhosttyKit ${stamp} is unavailable (${messageOf(cause)}). Run \`bun run ghostty:build\` only when intentionally rebuilding the shared artifact.`,
      { cause }
    )
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true })
  }
}

async function installFramework(source: string, destination: string): Promise<void> {
  const temporaryDestination = `${destination}.install-${process.pid}-${randomUUID()}`
  await mkdir(dirname(destination), { recursive: true })
  try {
    await cp(source, temporaryDestination, { recursive: true })
    await rm(destination, { recursive: true, force: true })
    await rename(temporaryDestination, destination)
  } finally {
    await rm(temporaryDestination, { recursive: true, force: true })
  }
}

async function linkLocalFramework(
  localFramework: string,
  cachedFramework: string,
  expectedStamp: string
): Promise<void> {
  const target = relative(dirname(localFramework), cachedFramework)
  const linked = await lstat(localFramework).then(
    (metadata) => metadata.isSymbolicLink(),
    () => false
  )
  if (
    linked &&
    (await validFramework(localFramework, expectedStamp)) &&
    (await readlink(localFramework)) === target
  )
    return

  await mkdir(dirname(localFramework), { recursive: true })
  await rm(localFramework, { recursive: true, force: true })
  await symlink(target, localFramework)
}

async function validRegularFramework(path: string, expectedStamp: string): Promise<boolean> {
  const isDirectory = await lstat(path).then(
    (metadata) => metadata.isDirectory(),
    () => false
  )
  return isDirectory && validFramework(path, expectedStamp)
}

function stampLock(artifactsRoot: string, stamp: string): string {
  return join(artifactsRoot, `.${stamp}.lock`)
}

async function sha256File(path: string): Promise<string> {
  const hash = createHash("sha256")
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest("hex")
}

async function run(command: string, args: ReadonlyArray<string>, cwd?: string): Promise<void> {
  console.log(`\n$ ${command} ${args.join(" ")}`)
  await runCommand(command, args, { cwd })
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
