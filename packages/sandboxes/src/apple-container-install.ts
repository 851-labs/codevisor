import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readdir, rename, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { ContainerCli } from "./apple-container-host.js"
import { SandboxProviderError } from "./provider.js"

export interface ContainerRelease {
  readonly version: string
  readonly url: string
  readonly sha256: string
}

export interface ContainerToolchain {
  readonly locate: () => Promise<ContainerCli | undefined>
  readonly install: (log: (line: string) => void) => Promise<void>
}

export interface ContainerInstallDeps {
  readonly candidates: ReadonlyArray<string>
  readonly version: (binary: string) => Promise<string | undefined>
  readonly download: (url: string) => Promise<Buffer>
  readonly expand: (pkg: string, target: string) => Promise<void>
}

export const CONTAINER_RELEASE: ContainerRelease = {
  version: "1.3.1",
  url: "https://github.com/apple/container/releases/download/1.3.1/container-1.3.1-installer-signed.pkg",
  sha256: "a7c1b9d7927d30875f2f6c7bd1d0cb06c2daa6ca57ce9e90a5144e898fdf54a8"
}

export const SUPPORTED_CONTAINER = { major: 1, minimumMinor: 3 } as const

export const containerToolchain = (
  toolsDir: string,
  deps: ContainerInstallDeps,
  release: ContainerRelease = CONTAINER_RELEASE
): ContainerToolchain => {
  const home = join(toolsDir, "container")
  const managed = join(home, release.version, "bin", "container")
  let located: ContainerCli | undefined
  const locate = async () => {
    located ??= await firstWorking([...deps.candidates, managed], deps.version)
    return located
  }
  let installing: Promise<void> | undefined
  return {
    locate,
    install: (log) => {
      installing ??= installRelease({ home, release, deps, locate, log }).finally(() => {
        installing = undefined
      })
      return installing
    }
  }
}

export const parseContainerVersion = (output: string): string | undefined =>
  /version (\d+\.\d+\.\d+)/.exec(output)?.[1]

export const isSupportedContainer = (version: string): boolean => {
  const match = /^(\d+)\.(\d+)\./.exec(version)
  if (match === null) return false

  return (
    Number(match[1]) === SUPPORTED_CONTAINER.major &&
    Number(match[2]) >= SUPPORTED_CONTAINER.minimumMinor
  )
}

interface InstallRequest {
  readonly home: string
  readonly release: ContainerRelease
  readonly deps: ContainerInstallDeps
  readonly locate: () => Promise<ContainerCli | undefined>
  readonly log: (line: string) => void
}

const firstWorking = async (
  binaries: ReadonlyArray<string>,
  version: (binary: string) => Promise<string | undefined>
): Promise<ContainerCli | undefined> => {
  for (const binary of binaries) {
    const found = await version(binary)
    if (found !== undefined) return { binary, version: found }
  }
  return undefined
}

const installRelease = async (request: InstallRequest): Promise<void> => {
  const { home, release, deps, log } = request
  if ((await request.locate()) !== undefined) return

  log(`Downloading Apple's container ${release.version}`)
  const pkg = await deps.download(release.url).catch((cause: unknown) => {
    throw installFailure(`Couldn't download Apple's container tool: ${messageOf(cause)}`)
  })
  if (sha256(pkg) !== release.sha256) {
    throw installFailure("The container download didn't match its checksum")
  }

  log(`Unpacking container into ${home}`)
  await unpack(home, release.version, pkg, deps)
  await pruneOtherVersions(home, release.version)
  if ((await request.locate()) === undefined) {
    throw installFailure("container was unpacked but can't run")
  }
  log(`Installed container ${release.version}`)
}

const unpack = async (
  home: string,
  version: string,
  pkg: Buffer,
  deps: ContainerInstallDeps
): Promise<void> => {
  await mkdir(home, { recursive: true })
  const staging = await mkdtemp(join(home, ".install-"))
  try {
    const pkgPath = join(staging, "container.pkg")
    const expanded = join(staging, "expanded")
    await writeFile(pkgPath, pkg)
    await deps.expand(pkgPath, expanded).catch(() => {
      throw installFailure("Couldn't unpack the container installer")
    })
    const target = join(home, version)
    await rm(target, { recursive: true, force: true })
    await rename(join(expanded, "Payload"), target)
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

const pruneOtherVersions = async (home: string, version: string): Promise<void> => {
  const stale = (await readdir(home)).filter((name) => name !== version)
  await Promise.all(stale.map((name) => rm(join(home, name), { recursive: true, force: true })))
}

const installFailure = (message: string): SandboxProviderError =>
  new SandboxProviderError("apple-container", message)

const sha256 = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex")

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
