import { runCli } from "./cli-process.js"
import type { GitHostSignInStatus } from "./git-host.js"

const statusTimeoutMs = 20_000
const accountPattern = /(?:account|as)\s+([A-Za-z0-9][\w.-]*)/

export const cliAuthStatus = async (
  path: string | undefined,
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv
): Promise<GitHostSignInStatus> => {
  if (path === undefined) return { cliInstalled: false, signedIn: false }

  const result = await runCli(path, args, env, { timeoutMs: statusTimeoutMs })
  if (result.exitCode !== 0) return { cliInstalled: true, signedIn: false }

  const account = accountPattern.exec(result.output)?.[1]
  return { cliInstalled: true, signedIn: true, ...(account === undefined ? {} : { account }) }
}
