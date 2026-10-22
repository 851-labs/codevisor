import { cliAuthStatus } from "./cli-auth-status.js"
import { detectCli, locateCli } from "./cli-detect.js"
import { makeCliInstaller } from "./cli-install.js"
import { startDeviceLogin } from "./cli-login.js"
import { currentPlatform, gitlabCliRelease } from "./cli-release.js"
import type { GitHost, GitHostTools } from "./git-host.js"

const command = "glab"

export const gitlabHost = (tools: GitHostTools = {}): GitHost => {
  const { toolsDir } = tools
  const glab = (env: NodeJS.ProcessEnv): string | undefined => locateCli(command, env, toolsDir)
  return {
    provider: "gitlab",
    command,
    cliName: gitlabCliRelease.cliName,
    detect: (env) => detectCli(command, env, toolsDir),
    install: makeCliInstaller(gitlabCliRelease, {
      toolsDir,
      platform: tools.platform ?? currentPlatform,
      releasesUrl: tools.releasesUrl ?? gitlabCliRelease.releasesUrl
    }),
    authStatus: (hostname, env) =>
      cliAuthStatus(glab(env), ["auth", "status", "--hostname", hostname], glabEnv(env)),
    login: (hostname, env, onDeviceCode) =>
      startDeviceLogin(
        { command, path: glab(env), args: loginArgs(hostname), env: glabEnv(env) },
        onDeviceCode
      )
  }
}

const loginArgs = (hostname: string): ReadonlyArray<string> => [
  "auth",
  "login",
  "--hostname",
  hostname,
  "--device",
  "--git-protocol",
  "https",
  "--setup-git-credential-helper"
]

const glabEnv = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => ({
  ...env,
  BROWSER: "true",
  GLAB_BROWSER: "true",
  NO_COLOR: "1",
  GLAB_CHECK_UPDATE: "false"
})
