import { execFile } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { mkdir, mkdtemp, readdir, rename, rm, symlink, writeFile } from "node:fs/promises"
import { basename, join } from "node:path"
import { promisify } from "node:util"

import { describeCli, managedBin } from "./cli-detect.js"
import { archiveName, checksumFor, type CliPlatform, type CliReleaseSpec } from "./cli-release.js"
import type { GitHostCli } from "./git-host.js"

export interface CliTools {
  readonly toolsDir: string | undefined
  readonly platform: CliPlatform
  readonly releasesUrl: string
}

export class CliInstallError extends Error {}

interface CliRelease {
  readonly tag: string
  readonly version: string
  readonly archive: string
}

const metadataTimeoutMs = 30_000
const archiveTimeoutMs = 5 * 60_000
const releaseTag = /^v(\d+\.\d+\.\d+)$/
const execFileAsync = promisify(execFile)

export const makeCliInstaller = (
  spec: CliReleaseSpec,
  tools: CliTools
): ((env: NodeJS.ProcessEnv) => Promise<GitHostCli>) => {
  let installing: Promise<GitHostCli> | undefined
  return (env) => {
    installing ??= installCli(spec, tools, env).finally(() => {
      installing = undefined
    })
    return installing
  }
}

const installCli = async (
  spec: CliReleaseSpec,
  tools: CliTools,
  env: NodeJS.ProcessEnv
): Promise<GitHostCli> => {
  const toolsDir = requireToolsDir(spec, tools)
  const suffix = requireAssetSuffix(spec, tools.platform)

  const release = await latestRelease(spec, tools, suffix)
  const archive = await verifiedArchive(spec, tools, release)

  const installed = await unpack(spec, toolsDir, release, archive)
  await linkCli(toolsDir, spec.command, join(installed, spec.binaryPath(release.archive)))
  await pruneOtherVersions(toolsDir, spec.command, release.version)

  return runnableCli(spec, toolsDir, env)
}

const requireToolsDir = (spec: CliReleaseSpec, tools: CliTools): string => {
  if (tools.toolsDir !== undefined) return tools.toolsDir
  throw new CliInstallError(`${spec.command} isn't installed on this machine`)
}

const requireAssetSuffix = (spec: CliReleaseSpec, platform: CliPlatform): string => {
  const suffix = spec.assetSuffix(platform)
  if (suffix !== undefined) return suffix
  throw new CliInstallError(
    `${spec.cliName} can't be installed on ${platform.os} ${platform.arch}.`
  )
}

const latestRelease = async (
  spec: CliReleaseSpec,
  tools: CliTools,
  suffix: string
): Promise<CliRelease> => {
  const response = await download(spec, spec.latestUrl(tools.releasesUrl), metadataTimeoutMs)
  const tag = basename(new URL(response.url).pathname)
  const version = releaseTag.exec(tag)?.[1]
  if (version === undefined) {
    throw new CliInstallError(`Couldn't find the latest ${spec.cliName} release.`)
  }

  return { tag, version, archive: archiveName(spec, version, suffix) }
}

const verifiedArchive = async (
  spec: CliReleaseSpec,
  tools: CliTools,
  release: CliRelease
): Promise<Buffer> => {
  const assetUrl = (name: string): string => spec.assetUrl(tools.releasesUrl, release.tag, name)
  const checksums = await downloadText(spec, assetUrl(spec.checksumsName(release.version)))
  const expected = checksumFor(checksums, release.archive)
  if (expected === undefined) {
    throw new CliInstallError(
      `${spec.cliName} ${release.version} has no checksum for this machine.`
    )
  }

  const archive = await downloadBytes(spec, assetUrl(release.archive))
  if (sha256(archive) !== expected) {
    throw new CliInstallError(`The ${spec.cliName} download didn't match its checksum.`)
  }
  return archive
}

const unpack = async (
  spec: CliReleaseSpec,
  toolsDir: string,
  release: CliRelease,
  archive: Buffer
): Promise<string> => {
  await mkdir(toolsDir, { recursive: true })
  const staging = await mkdtemp(join(toolsDir, ".install-"))
  try {
    const unpacked = await extract(spec, staging, release.archive, archive)
    const target = join(toolsDir, spec.command, release.version)
    await rm(target, { recursive: true, force: true })
    await mkdir(join(toolsDir, spec.command), { recursive: true })
    await rename(unpacked, target)
    return target
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

const extract = async (
  spec: CliReleaseSpec,
  staging: string,
  name: string,
  archive: Buffer
): Promise<string> => {
  const archivePath = join(staging, name)
  const unpacked = join(staging, "unpacked")
  await writeFile(archivePath, archive)
  await mkdir(unpacked)
  try {
    await execFileAsync("tar", ["-xf", archivePath, "-C", unpacked])
  } catch {
    throw new CliInstallError(`Couldn't unpack the ${spec.cliName} download.`)
  }
  return unpacked
}

const linkCli = async (toolsDir: string, command: string, binary: string): Promise<void> => {
  const bin = managedBin(toolsDir)
  await mkdir(bin, { recursive: true })
  const pending = join(bin, `.${command}-${randomUUID()}`)
  await symlink(binary, pending)
  await rename(pending, join(bin, command))
}

const pruneOtherVersions = async (
  toolsDir: string,
  command: string,
  version: string
): Promise<void> => {
  const versions = await readdir(join(toolsDir, command))
  const stale = versions.filter((name) => name !== version)
  await Promise.all(
    stale.map((name) => rm(join(toolsDir, command, name), { recursive: true, force: true }))
  )
}

const runnableCli = async (
  spec: CliReleaseSpec,
  toolsDir: string,
  env: NodeJS.ProcessEnv
): Promise<GitHostCli> => {
  const cli = await describeCli(join(managedBin(toolsDir), spec.command), env)
  if (cli.version !== undefined) return cli

  throw new CliInstallError(`${spec.cliName} was installed but doesn't run.`)
}

const download = async (
  spec: CliReleaseSpec,
  url: string,
  timeoutMs: number
): Promise<Response> => {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) }).catch(() => {
    throw offline(spec)
  })
  if (response.ok) return response

  throw new CliInstallError(`Couldn't download ${spec.cliName} (HTTP ${String(response.status)}).`)
}

const downloadText = async (spec: CliReleaseSpec, url: string): Promise<string> => {
  const response = await download(spec, url, metadataTimeoutMs)
  return response.text().catch(() => {
    throw offline(spec)
  })
}

const downloadBytes = async (spec: CliReleaseSpec, url: string): Promise<Buffer> => {
  const response = await download(spec, url, archiveTimeoutMs)
  const bytes = await response.arrayBuffer().catch(() => {
    throw offline(spec)
  })
  return Buffer.from(bytes)
}

const offline = (spec: CliReleaseSpec): CliInstallError =>
  new CliInstallError(
    `Couldn't download ${spec.cliName}. Check this machine's internet connection.`
  )

const sha256 = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex")
