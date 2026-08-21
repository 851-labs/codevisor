import { mkdir } from "node:fs/promises"
import { join } from "node:path"

export const IOS_DEVELOPMENT_BUNDLE_IDENTIFIER = "com.851labs.Codevisor.Development.iOS"

export function legacyIOSDevelopmentBundleIdentifiers(listAppsOutput) {
  return [
    ...listAppsOutput.matchAll(/^\s*"?(com\.dylanplayer\.codevisor\.ios\.[0-9a-f]{10})"?\s*=/gim)
  ].map((match) => match[1])
}

export function developmentLayout(repoRoot, environment = process.env) {
  const tmpRoot = join(repoRoot, "tmp")
  const localCodevisorRoot = join(tmpRoot, ".codevisor")
  const remoteRoot = join(tmpRoot, "remote")
  const remoteCodevisorRoot = join(remoteRoot, ".codevisor")
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
    remote: {
      root: remoteCodevisorRoot,
      data: join(remoteCodevisorRoot, "data"),
      logs: join(remoteCodevisorRoot, "logs"),
      repos: join(remoteCodevisorRoot, "repos"),
      plugins: join(remoteCodevisorRoot, "plugins"),
      cache: join(remoteCodevisorRoot, "cache"),
      worktrees: join(remoteRoot, "codevisor")
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
      packageCache: join(buildRoot, "swift-package-cache"),
      bunCache: join(buildRoot, "bun-cache"),
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
      layout.remote.data,
      layout.remote.logs,
      layout.remote.repos,
      layout.remote.plugins,
      layout.remote.cache,
      layout.remote.worktrees,
      layout.build.generated,
      layout.build.bunCache,
      layout.build.nodeGyp,
      layout.runtime.temp,
      layout.wrangler
    ].map((directory) => mkdir(directory, { recursive: true }))
  )
}

export async function ensureBuildDirectories(layout) {
  await Promise.all(
    [layout.build.bunCache, layout.build.nodeGyp, layout.build.generated, layout.runtime.temp].map(
      (directory) => mkdir(directory, { recursive: true })
    )
  )
}

export function localDevelopmentEnvironment(layout, environment = process.env) {
  return {
    ...environment,
    TMPDIR: layout.runtime.temp,
    BUN_INSTALL_CACHE_DIR: layout.build.bunCache,
    npm_config_devdir: layout.build.nodeGyp,
    ...(process.platform === "darwin" ? { npm_config_python: "/usr/bin/python3" } : {}),
    CODEVISOR_DEV_DATA_DIR: layout.local.data,
    CODEVISOR_DEV_LOGS_DIR: layout.local.logs,
    CODEVISOR_DEV_CACHE_DIR: layout.local.cache,
    CODEVISOR_DATA_DIR: layout.local.data,
    CODEVISOR_LOGS_DIR: layout.local.logs,
    CODEVISOR_WORKTREES_ROOT: layout.local.worktrees,
    CODEVISOR_REPOS_ROOT: layout.local.repos,
    CODEVISOR_PLUGINS_ROOT: layout.local.plugins
  }
}

export function remoteDevelopmentEnvironment(layout, environment = process.env) {
  return {
    ...environment,
    TMPDIR: layout.runtime.temp,
    BUN_INSTALL_CACHE_DIR: layout.build.bunCache,
    npm_config_devdir: layout.build.nodeGyp,
    ...(process.platform === "darwin" ? { npm_config_python: "/usr/bin/python3" } : {}),
    CODEVISOR_DEV_DATA_DIR: layout.remote.data,
    CODEVISOR_DEV_LOGS_DIR: layout.remote.logs,
    CODEVISOR_DEV_CACHE_DIR: layout.remote.cache,
    CODEVISOR_DATA_DIR: layout.remote.data,
    CODEVISOR_LOGS_DIR: layout.remote.logs,
    CODEVISOR_WORKTREES_ROOT: layout.remote.worktrees,
    CODEVISOR_REPOS_ROOT: layout.remote.repos,
    CODEVISOR_PLUGINS_ROOT: layout.remote.plugins
  }
}
