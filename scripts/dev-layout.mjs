import { createHash } from "node:crypto"
import { mkdir } from "node:fs/promises"
import { join } from "node:path"

export const IOS_DEVELOPMENT_BUNDLE_IDENTIFIER = "com.851labs.Codevisor.Development.iOS"

export function iosDevelopmentBundleIdentifier(repoRoot) {
  const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  return `${IOS_DEVELOPMENT_BUNDLE_IDENTIFIER}.${instanceHash}`
}

export function developmentLayout(repoRoot, environment = process.env) {
  const tmpRoot = join(repoRoot, "tmp")
  const localCodevisorRoot = join(tmpRoot, ".codevisor")
  const remoteRoot = join(tmpRoot, "remote")
  const remoteCodevisorRoot = join(remoteRoot, ".codevisor")
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
    // The direct-connection test server (added by token/deeplink, never in
    // the dev cloud). Keeps the original tmp/remote roots so existing dev
    // state carries over.
    remote: {
      root: remoteCodevisorRoot,
      data: join(remoteCodevisorRoot, "data"),
      logs: join(remoteCodevisorRoot, "logs"),
      repos: join(remoteCodevisorRoot, "repos"),
      plugins: join(remoteCodevisorRoot, "plugins"),
      cache: join(remoteCodevisorRoot, "cache"),
      worktrees: join(remoteRoot, "codevisor")
    },
    // The cloud test server (signs into the dev cloud; reached through the
    // relay, never added directly).
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

// `remote` picks which standalone server's roots to use: layout.remote (the
// direct-connection server, the default) or layout.remoteCloud (the cloud
// test server).
export function remoteDevelopmentEnvironment(
  layout,
  environment = process.env,
  remote = layout.remote
) {
  return {
    ...environment,
    TMPDIR: layout.runtime.temp,
    BUN_INSTALL_CACHE_DIR: layout.build.bunCache,
    npm_config_devdir: layout.build.nodeGyp,
    ...(process.platform === "darwin" ? { npm_config_python: "/usr/bin/python3" } : {}),
    CODEVISOR_DEV_DATA_DIR: remote.data,
    CODEVISOR_DEV_LOGS_DIR: remote.logs,
    CODEVISOR_DEV_CACHE_DIR: remote.cache,
    CODEVISOR_DATA_DIR: remote.data,
    CODEVISOR_LOGS_DIR: remote.logs,
    CODEVISOR_WORKTREES_ROOT: remote.worktrees,
    CODEVISOR_REPOS_ROOT: remote.repos,
    CODEVISOR_PLUGINS_ROOT: remote.plugins
  }
}
