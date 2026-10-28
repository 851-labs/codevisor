import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { constants } from "node:fs"
import { access, mkdir, mkdtemp, readdir, rename, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import { SandboxProviderError } from "./provider.js"

export interface TartRelease {
  readonly version: string
  readonly url: string
  readonly sha256: string
}

export interface TartInstall {
  readonly binary: string
  readonly installed: () => Promise<boolean>
  readonly install: (log: (line: string) => void) => Promise<void>
}

export type TartDownload = (url: string) => Promise<Buffer>

export const TART_RELEASE: TartRelease = {
  version: "2.41.1",
  url: "https://github.com/openai/tart/releases/download/2.41.1/tart.tar.gz",
  sha256: "e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2"
}

const execFileAsync = promisify(execFile)

export const systemTart = (binary: string): TartInstall => ({
  binary,
  installed: () => Promise.resolve(true),
  install: () => Promise.resolve()
})

export const managedTart = (
  toolsDir: string,
  download: TartDownload,
  release: TartRelease = TART_RELEASE
): TartInstall => {
  const home = join(toolsDir, "tart")
  const binary = join(home, release.version, "tart.app", "Contents", "MacOS", "tart")
  const installed = () => isExecutable(binary)
  let installing: Promise<void> | undefined
  return {
    binary,
    installed,
    install: (log) => {
      installing ??= installRelease({ home, release, download, installed, log }).finally(() => {
        installing = undefined
      })
      return installing
    }
  }
}

interface InstallRequest {
  readonly home: string
  readonly release: TartRelease
  readonly download: TartDownload
  readonly installed: () => Promise<boolean>
  readonly log: (line: string) => void
}

const installRelease = async (request: InstallRequest): Promise<void> => {
  const { home, release, log } = request
  if (await request.installed()) return

  log(`Downloading Tart ${release.version}`)
  const archive = await request.download(release.url).catch((cause: unknown) => {
    throw tartFailure(`Couldn't download Tart: ${messageOf(cause)}`)
  })
  if (sha256(archive) !== release.sha256) {
    throw tartFailure("The Tart download didn't match its checksum")
  }

  log(`Unpacking Tart into ${home}`)
  await unpack(home, release.version, archive)
  await pruneOtherVersions(home, release.version)
  if (!(await request.installed())) throw tartFailure("Tart was unpacked but can't run")
  log(`Installed Tart ${release.version}`)
}

const unpack = async (home: string, version: string, archive: Buffer): Promise<void> => {
  await mkdir(home, { recursive: true })
  const staging = await mkdtemp(join(home, ".install-"))
  try {
    const archivePath = join(staging, "tart.tar.gz")
    const unpacked = join(staging, "unpacked")
    await writeFile(archivePath, archive)
    await mkdir(unpacked)
    await execFileAsync("tar", ["-xzf", archivePath, "-C", unpacked]).catch(() => {
      throw tartFailure("Couldn't unpack the Tart download")
    })
    const target = join(home, version)
    await rm(target, { recursive: true, force: true })
    await rename(unpacked, target)
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

const pruneOtherVersions = async (home: string, version: string): Promise<void> => {
  const stale = (await readdir(home)).filter((name) => name !== version)
  await Promise.all(stale.map((name) => rm(join(home, name), { recursive: true, force: true })))
}

const isExecutable = async (path: string): Promise<boolean> => {
  try {
    await access(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

const tartFailure = (message: string): SandboxProviderError =>
  new SandboxProviderError("tart", message)

const sha256 = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex")

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
