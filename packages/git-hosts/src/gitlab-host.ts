import { cliAuthStatus } from "./cli-auth-status.js"
import { detectCli, locateCli } from "./cli-detect.js"
import { startDeviceLogin } from "./cli-login.js"
import type { GitHost } from "./git-host.js"

const command = "glab"

export const gitlabHost = (): GitHost => ({
  provider: "gitlab",
  command,
  cliName: "GitLab CLI",
  detect: (env) => detectCli(command, env),
  authStatus: (hostname, env) =>
    cliAuthStatus(
      locateCli(command, env),
      ["auth", "status", "--hostname", hostname],
      glabEnv(env)
    ),
  login: (hostname, env, onDeviceCode) =>
    startDeviceLogin(
      { command, path: locateCli(command, env), args: loginArgs(hostname), env: glabEnv(env) },
      onDeviceCode
    )
})

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
