import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { mkdir, rename } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import { instanceWorktreesRoot } from "./dev-instance-roots.ts"
import { isMissing } from "./files.ts"

export const IOS_DEVELOPMENT_BUNDLE_IDENTIFIER = "com.851labs.Codevisor.Development.iOS"

export interface ServiceRoots {
  readonly root: string
  readonly data: string
  readonly logs: string
  readonly repos: string
  readonly plugins: string
  readonly cache: string
  readonly worktrees: string
}

export interface AppBuildRoots {
  readonly derivedData: string
  readonly sourcePackages: string
}

export interface DevelopmentLayout {
  readonly tmpRoot: string
  readonly local: ServiceRoots
  readonly remoteCloud: ServiceRoots
  readonly build: {
    readonly root: string
    readonly macos: AppBuildRoots
    readonly ios: AppBuildRoots
    readonly pixelbook: AppBuildRoots
    readonly packageCache: string
    readonly swiftArtifactStore: string
    readonly bunCache: string
    readonly legacyBunCache: string
    readonly nodeGyp: string
    readonly generated: string
    readonly turboCache: string
  }
  readonly wrangler: string
  readonly runtime: { readonly root: string; readonly temp: string; readonly manifest: string }
}

type Environment = Readonly<Record<string, string | undefined>>

export function iosDevelopmentBundleIdentifier(repoRoot: string): string {
  const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  return `${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}.${instanceHash}`
}

export function developmentLayout(
  repoRoot: string,
  environment: Environment = process.env
): DevelopmentLayout {
  const tmpRoot = join(repoRoot, "tmp")
  const buildRoot = join(tmpRoot, "build")
  return {
    tmpRoot,
    local: localRoots(repoRoot, tmpRoot, environment),
    remoteCloud: remoteCloudRoots(tmpRoot),
    build: {
      root: buildRoot,
      macos: appBuildRoots(buildRoot, "macos"),
      ios: appBuildRoots(buildRoot, "ios"),
      pixelbook: appBuildRoots(buildRoot, "pixelbook"),
      packageCache:
        environment.CODEVISOR_SWIFT_PACKAGE_CACHE ?? sharedArtifact("swift-package-cache"),
      swiftArtifactStore:
        environment.CODEVISOR_SWIFT_ARTIFACT_STORE ?? sharedArtifact("swift-artifacts"),
      bunCache: environment.CODEVISOR_BUN_CACHE ?? sharedArtifact("bun-cache"),
      legacyBunCache: join(buildRoot, "bun-cache"),
      nodeGyp: join(buildRoot, "node-gyp"),
      generated: join(buildRoot, "generated"),
      turboCache: join(buildRoot, "turbo-cache")
    },
    wrangler: join(tmpRoot, ".wrangler"),
    runtime: {
      root: join(tmpRoot, "runtime"),
      temp: join(tmpRoot, "runtime", "temp"),
      manifest: join(tmpRoot, "runtime", "manifest.json")
    }
  }
}

export async function ensureDevelopmentDirectories(layout: DevelopmentLayout): Promise<void> {
  await makeDirectories([
    ...serviceDirectories(layout.local),
    ...serviceDirectories(layout.remoteCloud),
    layout.build.generated,
    layout.build.bunCache,
    layout.build.nodeGyp,
    layout.runtime.temp,
    layout.wrangler
  ])
  await discardLegacyBunCache(layout)
}

export async function ensureBuildDirectories(layout: DevelopmentLayout): Promise<void> {
  await makeDirectories([
    layout.build.bunCache,
    layout.build.nodeGyp,
    layout.build.generated,
    layout.runtime.temp
  ])
  await discardLegacyBunCache(layout)
}

export async function discardLegacyBunCache(
  layout: DevelopmentLayout,
  remove: (path: string) => void = removeInBackground
): Promise<boolean> {
  if (layout.build.legacyBunCache === layout.build.bunCache) return false

  const discarded = join(layout.build.root, `.bun-cache-discarded-${randomUUID()}`)
  try {
    await rename(layout.build.legacyBunCache, discarded)
  } catch (error) {
    if (isMissing(error)) return false
    throw error
  }
  remove(discarded)
  return true
}

export function localDevelopmentEnvironment(
  layout: DevelopmentLayout,
  environment: Environment = process.env
): Record<string, string | undefined> {
  return developmentEnvironment(layout, layout.local, environment)
}

export function remoteDevelopmentEnvironment(
  layout: DevelopmentLayout,
  environment: Environment = process.env
): Record<string, string | undefined> {
  return developmentEnvironment(layout, layout.remoteCloud, environment)
}

function localRoots(repoRoot: string, tmpRoot: string, environment: Environment): ServiceRoots {
  const root = join(tmpRoot, ".codevisor")
  return {
    root,
    data:
      environment.CODEVISOR_DEV_DATA_DIR ?? environment.HERDMAN_DEV_DATA_DIR ?? join(root, "data"),
    logs: environment.CODEVISOR_DEV_LOGS_DIR ?? join(root, "logs"),
    repos: environment.CODEVISOR_REPOS_ROOT ?? join(root, "repos"),
    plugins: environment.CODEVISOR_PLUGINS_ROOT ?? join(root, "plugins"),
    cache: environment.CODEVISOR_DEV_CACHE_DIR ?? join(root, "cache"),
    worktrees:
      environment.CODEVISOR_WORKTREES_ROOT ??
      environment.HERDMAN_WORKTREES_ROOT ??
      instanceWorktreesRoot(repoRoot)
  }
}

function remoteCloudRoots(tmpRoot: string): ServiceRoots {
  const parent = join(tmpRoot, "remote-cloud")
  const root = join(parent, ".codevisor")
  return {
    root,
    data: join(root, "data"),
    logs: join(root, "logs"),
    repos: join(root, "repos"),
    plugins: join(root, "plugins"),
    cache: join(root, "cache"),
    worktrees: join(parent, "codevisor")
  }
}

function appBuildRoots(buildRoot: string, app: string): AppBuildRoots {
  return {
    derivedData: join(buildRoot, app, "DerivedData"),
    sourcePackages: join(buildRoot, app, "SourcePackages")
  }
}

function sharedArtifact(name: string): string {
  return join(homedir(), ".codevisor-development", "artifacts", name)
}

function serviceDirectories(roots: ServiceRoots): Array<string> {
  return [roots.data, roots.logs, roots.repos, roots.plugins, roots.cache, roots.worktrees]
}

async function makeDirectories(directories: ReadonlyArray<string>): Promise<void> {
  await Promise.all(directories.map((directory) => mkdir(directory, { recursive: true })))
}

function developmentEnvironment(
  layout: DevelopmentLayout,
  roots: ServiceRoots,
  environment: Environment
): Record<string, string | undefined> {
  return {
    ...environment,
    TMPDIR: layout.runtime.temp,
    BUN_INSTALL_CACHE_DIR: layout.build.bunCache,
    npm_config_devdir: layout.build.nodeGyp,
    ...(process.platform === "darwin" ? { npm_config_python: "/usr/bin/python3" } : {}),
    CODEVISOR_DEV_DATA_DIR: roots.data,
    CODEVISOR_DEV_LOGS_DIR: roots.logs,
    CODEVISOR_DEV_CACHE_DIR: roots.cache,
    CODEVISOR_DATA_DIR: roots.data,
    CODEVISOR_LOGS_DIR: roots.logs,
    CODEVISOR_WORKTREES_ROOT: roots.worktrees,
    CODEVISOR_REPOS_ROOT: roots.repos,
    CODEVISOR_PLUGINS_ROOT: roots.plugins
  }
}

function removeInBackground(path: string): void {
  spawn("/bin/rm", ["-rf", "--", path], { detached: true, stdio: "ignore" }).unref()
}
