import { mkdir, symlink } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

import type { AppliedGitSignIn, GitSignIn } from "@codevisor/api"
import type { GitHost, GitHostCli, GitHosts } from "@codevisor/git-hosts"

import { failureMessage } from "../server-http.js"

export const SANDBOX_GIT_HOSTS: ReadonlyArray<string> = ["github.com"]

export interface SavedGitSignIns {
  readonly saved: () => Promise<ReadonlyArray<GitSignIn>>
}

export const copiesToSandboxes = (host: string): boolean =>
  SANDBOX_GIT_HOSTS.includes(host.trim().toLowerCase())

export const makeSavedGitSignIns = (
  hosts: GitHosts,
  resolveEnvironment: () => Promise<NodeJS.ProcessEnv>
): SavedGitSignIns => ({
  saved: async () => {
    const env = await resolveEnvironment()
    const found = await Promise.all(SANDBOX_GIT_HOSTS.map((host) => savedSignIn(hosts, host, env)))
    return found.flat()
  }
})

export const applyGitSignIn = async (
  hosts: GitHosts,
  signIn: GitSignIn,
  env: NodeJS.ProcessEnv
): Promise<AppliedGitSignIn> => {
  const host = signIn.host.trim().toLowerCase()
  const gitHost = hosts.forHost(host)
  if (gitHost?.signInWithToken === undefined) {
    return { host, signedIn: false, message: `Copying a sign-in for ${host} isn't supported yet` }
  }

  try {
    return await signInWith(gitHost, { host, token: signIn.token }, env)
  } catch (cause) {
    return { host, signedIn: false, message: failureMessage(cause) }
  }
}

const savedSignIn = async (
  hosts: GitHosts,
  host: string,
  env: NodeJS.ProcessEnv
): Promise<ReadonlyArray<GitSignIn>> => {
  const token = await hosts.forHost(host)?.token?.(host, env)
  if (token === undefined) return []
  return [{ host, token }]
}

const signInWith = async (
  gitHost: GitHost,
  signIn: GitSignIn,
  env: NodeJS.ProcessEnv
): Promise<AppliedGitSignIn> => {
  const cli = (await gitHost.detect(env)) ?? (await gitHost.install(env))
  const result = await gitHost.signInWithToken?.(signIn.host, signIn.token, env)
  if (result?.signedIn !== true) {
    return { host: signIn.host, signedIn: false, message: result?.message ?? "Sign-in failed" }
  }

  await gitHost.setUpGitCredentials?.(signIn.host, env)
  await putOnPath(gitHost.command, cli, env)
  const { account } = await gitHost.authStatus(signIn.host, env)
  return { host: signIn.host, signedIn: true, ...(account === undefined ? {} : { account }) }
}

const putOnPath = async (
  command: string,
  cli: GitHostCli,
  env: NodeJS.ProcessEnv
): Promise<void> => {
  if (pathDirectories(env).includes(dirname(cli.path))) return

  const userBin = join(env.HOME ?? homedir(), ".local", "bin")
  await mkdir(userBin, { recursive: true })
  await symlink(cli.path, join(userBin, command)).catch(ignoreExisting)
}

const pathDirectories = (env: NodeJS.ProcessEnv): ReadonlyArray<string> =>
  (env.PATH ?? "").split(":")

const ignoreExisting = (cause: NodeJS.ErrnoException): void => {
  if (cause.code !== "EEXIST") throw cause
}
