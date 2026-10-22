import { cliAuthStatus } from "./cli-auth-status.js"
import { detectCli, locateCli } from "./cli-detect.js"
import { startDeviceLogin } from "./cli-login.js"
import { runCli } from "./cli-process.js"
import type { GitHost, PullRequestHost } from "./git-host.js"
import { findGithubPullRequest } from "./github-pull-request.js"

const command = "gh"
const setupGitTimeoutMs = 20_000

export const githubHost = (): GitHost & PullRequestHost => ({
  provider: "github",
  command,
  cliName: "GitHub CLI",
  detect: (env) => detectCli(command, env),
  authStatus: (hostname, env) =>
    cliAuthStatus(locateCli(command, env), ["auth", "status", "--hostname", hostname], ghEnv(env)),
  login: (hostname, env, onDeviceCode) =>
    startDeviceLogin(
      { command, path: locateCli(command, env), args: loginArgs(hostname), env: ghEnv(env) },
      onDeviceCode
    ),
  setUpGitCredentials: async (hostname, env) => {
    const gh = locateCli(command, env)
    if (gh === undefined) return

    await runCli(gh, ["auth", "setup-git", "--hostname", hostname], ghEnv(env), {
      timeoutMs: setupGitTimeoutMs
    })
  },
  findPullRequest: (directory, env, branch, owned) =>
    findGithubPullRequest(locateCli(command, env), directory, env, branch, owned)
})

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
