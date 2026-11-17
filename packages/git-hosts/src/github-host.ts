import { cliAuthStatus } from "./cli-auth-status.js"
import { detectCli, locateCli } from "./cli-detect.js"
import { makeCliInstaller } from "./cli-install.js"
import { startDeviceLogin } from "./cli-login.js"
import { runCli } from "./cli-process.js"
import { currentPlatform, githubCliRelease } from "./cli-release.js"
import type { GitHost, GitHostLoginResult, GitHostTools, PullRequestHost } from "./git-host.js"
import { findGithubPullRequest } from "./github-pull-request.js"

const command = "gh"
const setupGitTimeoutMs = 20_000
const tokenTimeoutMs = 20_000

export const githubHost = (tools: GitHostTools = {}): GitHost & PullRequestHost => {
  const { toolsDir } = tools
  const gh = (env: NodeJS.ProcessEnv): string | undefined => locateCli(command, env, toolsDir)
  return {
    provider: "github",
    command,
    cliName: githubCliRelease.cliName,
    detect: (env) => detectCli(command, env, toolsDir),
    install: makeCliInstaller(githubCliRelease, {
      toolsDir,
      platform: tools.platform ?? currentPlatform,
      releasesUrl: tools.releasesUrl ?? githubCliRelease.releasesUrl
    }),
    authStatus: (hostname, env) =>
      cliAuthStatus(gh(env), ["auth", "status", "--hostname", hostname], ghEnv(env)),
    login: (hostname, env, onDeviceCode) =>
      startDeviceLogin(
        { command, path: gh(env), args: loginArgs(hostname), env: ghEnv(env) },
        onDeviceCode
      ),
    setUpGitCredentials: async (hostname, env) => {
      const path = gh(env)
      if (path === undefined) return

      await runCli(path, ["auth", "setup-git", "--hostname", hostname], ghEnv(env), {
        timeoutMs: setupGitTimeoutMs
      })
    },
    token: (hostname, env) => savedToken(gh(env), hostname, ghEnv(env)),
    signInWithToken: (hostname, token, env) =>
      signInWithToken(gh(env), hostname, token, ghEnv(env)),
    findPullRequest: (directory, env, branch, owned) =>
      findGithubPullRequest(gh(env), directory, env, branch, owned)
  }
}

const savedToken = async (
  path: string | undefined,
  hostname: string,
  env: NodeJS.ProcessEnv
): Promise<string | undefined> => {
  if (path === undefined) return undefined

  const result = await runCli(path, ["auth", "token", "--hostname", hostname], env, {
    timeoutMs: tokenTimeoutMs
  })
  const token = result.stdout.trim()
  if (result.exitCode !== 0 || token.length === 0) return undefined
  return token
}

const signInWithToken = async (
  path: string | undefined,
  hostname: string,
  token: string,
  env: NodeJS.ProcessEnv
): Promise<GitHostLoginResult> => {
  if (path === undefined) return { signedIn: false, message: `${command} isn't installed` }

  const result = await runCli(path, tokenLoginArgs(hostname), env, {
    timeoutMs: tokenTimeoutMs,
    stdin: `${token}\n`
  })
  if (result.exitCode === 0) return { signedIn: true }
  return { signedIn: false, message: result.output.replaceAll(token, "[token]").trim() }
}

const tokenLoginArgs = (hostname: string): ReadonlyArray<string> => [
  "auth",
  "login",
  "--hostname",
  hostname,
  "--with-token",
  "--git-protocol",
  "https",
  "--insecure-storage"
]

const loginArgs = (hostname: string): ReadonlyArray<string> => [
  "auth",
  "login",
  "--web",
  "--hostname",
  hostname,
  "--git-protocol",
  "https",
  "--skip-ssh-key"
]

const ghEnv = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => ({
  ...env,
  BROWSER: "true",
  GH_BROWSER: "true",
  NO_COLOR: "1",
  GH_NO_UPDATE_NOTIFIER: "1"
})
