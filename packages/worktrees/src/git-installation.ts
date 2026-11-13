import { execFileSync, type ExecFileSyncOptionsWithStringEncoding } from "node:child_process"
import { accessSync, constants, realpathSync } from "node:fs"
import { join } from "node:path"

export type GitInstallation =
  | { readonly state: "ready"; readonly path: string }
  | { readonly state: "missing" }

export interface GitHost {
  readonly platform: NodeJS.Platform
  readonly isExecutable: (path: string) => boolean
  readonly realPath: (path: string) => string
  readonly developerDirectory: () => string | undefined
}

export const locateGit = (
  env: NodeJS.ProcessEnv,
  host: GitHost = systemGitHost
): GitInstallation => {
  const path = gitCandidates(env, host).find((candidate) => isRealGit(candidate, host))
  return path === undefined ? { state: "missing" } : { state: "ready", path }
}

export const hasAppleDeveloperTool = (
  tool: string,
  host: Pick<GitHost, "isExecutable" | "developerDirectory"> = systemGitHost
): boolean => {
  const developer = host.developerDirectory()
  if (developer === undefined) return false

  return host.isExecutable(join(developer, "usr", "bin", tool))
}

export const systemGitHost: GitHost = {
  platform: process.platform,
  isExecutable: (path) => {
    try {
      accessSync(path, constants.X_OK)
      return true
    } catch {
      return false
    }
  },
  realPath: (path) => {
    try {
      return realpathSync(path)
    } catch {
      return path
    }
  },
  developerDirectory: () => {
    try {
      const directory = execFileSync(xcodeSelect, ["-p"], xcodeSelectOptions).trim()
      return directory.length > 0 ? directory : undefined
    } catch {
      return undefined
    }
  }
}

const appleGitStub = "/usr/bin/git"

const xcodeSelect = "/usr/bin/xcode-select"

const xcodeSelectOptions: ExecFileSyncOptionsWithStringEncoding = {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "ignore"],
  timeout: 5_000
}

const gitCandidates = (env: NodeJS.ProcessEnv, host: GitHost): ReadonlyArray<string> =>
  (env.PATH ?? "")
    .split(":")
    .filter((directory) => directory.length > 0)
    .map((directory) => join(directory, "git"))
    .filter(host.isExecutable)

const isRealGit = (candidate: string, host: GitHost): boolean =>
  !isAppleStub(candidate, host) || hasAppleDeveloperTool("git", host)

const isAppleStub = (candidate: string, host: GitHost): boolean =>
  host.platform === "darwin" && host.realPath(candidate) === appleGitStub
