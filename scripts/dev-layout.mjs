import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { mkdir, rename } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

export const IOS_DEVELOPMENT_BUNDLE_IDENTIFIER = "com.851labs.Codevisor.Development.iOS"

export function iosDevelopmentBundleIdentifier(repoRoot) {
  const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  return `${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}.${instanceHash}`
}

export function developmentLayout(repoRoot, environment = process.env) {
  const tmpRoot = join(repoRoot, "tmp")
  const localCodevisorRoot = join(tmpRoot, ".codevisor")
  const remoteCloudRoot = join(tmpRoot, "remote-cloud")
  const remoteCloudCodevisorRoot = join(remoteCloudRoot, ".codevisor")
  const buildRoot = join(tmpRoot, "build")

  return {
    tmpRoot,
    local: {
      root: localCodevisorRoot,
      data:
        environment.CODEVISOR_DEV_DATA_DIR ??
        environment.HERDMAN_DEV_DATA_DIR ??
        join(localCodevisorRoot, "data"),
      logs: environment.CODEVISOR_DEV_LOGS_DIR ?? join(localCodevisorRoot, "logs"),
      repos: environment.CODEVISOR_REPOS_ROOT ?? join(localCodevisorRoot, "repos"),
      plugins: environment.CODEVISOR_PLUGINS_ROOT ?? join(localCodevisorRoot, "plugins"),
      cache: environment.CODEVISOR_DEV_CACHE_DIR ?? join(localCodevisorRoot, "cache"),
      worktrees:
        environment.CODEVISOR_WORKTREES_ROOT ??
        environment.HERDMAN_WORKTREES_ROOT ??
        join(tmpRoot, "codevisor")
    },
    remoteCloud: {
      root: remoteCloudCodevisorRoot,
      data: join(remoteCloudCodevisorRoot, "data"),
      logs: join(remoteCloudCodevisorRoot, "logs"),
      repos: join(remoteCloudCodevisorRoot, "repos"),
      plugins: join(remoteCloudCodevisorRoot, "plugins"),
      cache: join(remoteCloudCodevisorRoot, "cache"),
      worktrees: join(remoteCloudRoot, "codevisor")
    },
    build: {
      root: buildRoot,
      macos: {
        derivedData: join(buildRoot, "macos", "DerivedData"),
        sourcePackages: join(buildRoot, "macos", "SourcePackages")
      },
      ios: {
        derivedData: join(buildRoot, "ios", "DerivedData"),
        sourcePackages: join(buildRoot, "ios", "SourcePackages")
      },
      pixelbook: {
        derivedData: join(buildRoot, "pixelbook", "DerivedData"),
        sourcePackages: join(buildRoot, "pixelbook", "SourcePackages")
      },
      packageCache:
        environment.CODEVISOR_SWIFT_PACKAGE_CACHE ??
        join(homedir(), ".codevisor-development", "artifacts", "swift-package-cache"),
      swiftArtifactStore:
        environment.CODEVISOR_SWIFT_ARTIFACT_STORE ??
        join(homedir(), ".codevisor-development", "artifacts", "swift-artifacts"),
      bunCache:
        environment.CODEVISOR_BUN_CACHE ??
        join(homedir(), ".codevisor-development", "artifacts", "bun-cache"),
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

export async function ensureDevelopmentDirectories(layout) {
  await Promise.all(
    [
      layout.local.data,
      layout.local.logs,
      layout.local.repos,
      layout.local.plugins,
      layout.local.cache,
      layout.local.worktrees,
      layout.remoteCloud.data,
      layout.remoteCloud.logs,
      layout.remoteCloud.repos,
      layout.remoteCloud.plugins,
      layout.remoteCloud.cache,
      layout.remoteCloud.worktrees,
      layout.build.generated,
      layout.build.bunCache,
      layout.build.nodeGyp,
      layout.runtime.temp,
      layout.wrangler
    ].map((directory) => mkdir(directory, { recursive: true }))
  )
  await discardLegacyBunCache(layout)
}

export async function ensureBuildDirectories(layout) {
  await Promise.all(
    [layout.build.bunCache, layout.build.nodeGyp, layout.build.generated, layout.runtime.temp].map(
      (directory) => mkdir(directory, { recursive: true })
    )
  )
  await discardLegacyBunCache(layout)
}

export async function discardLegacyBunCache(layout, remove = removeInBackground) {
  if (layout.build.legacyBunCache === layout.build.bunCache) return false
  const discarded = join(layout.build.root, `.bun-cache-discarded-${randomUUID()}`)
  try {
    await rename(layout.build.legacyBunCache, discarded)
  } catch (error) {
    if (error.code === "ENOENT") return false
    throw error
  }
  remove(discarded)
  return true
}

function removeInBackground(path) {
  spawn("/bin/rm", ["-rf", "--", path], { detached: true, stdio: "ignore" }).unref()
}

export function localDevelopmentEnvironment(layout, environment = process.env) {
  return developmentEnvironment(layout, layout.local, environment)
}

export function remoteDevelopmentEnvironment(layout, environment = process.env) {
  return developmentEnvironment(layout, layout.remoteCloud, environment)
}

function developmentEnvironment(layout, roots, environment) {
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
