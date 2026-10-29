import { execFile } from "node:child_process"
import { homedir } from "node:os"

import type { TrustFlag } from "./harness-definition-types.js"
import type { FlagSupport, ProviderEnvironment } from "./types.js"
import { binaryIdentity } from "./version-probe.js"

// oxlint-disable-next-line codevisor/no-comments
// Codevisor launches every harness trusted, so repo hooks, plugins and project config run as trusted code, as they already do in Claude Code.
export const TRUSTED_LAUNCH = {
  codexConfig: { bypass_hook_trust: true },
  cursor: { args: ["--trust"], probe: ["--help"], probeMentions: "--trust" },
  geminiEnv: { GEMINI_CLI_TRUST_WORKSPACE: "true" },
  grok: { args: ["--trust"], probe: ["--trust", "--version"] },
  museArgs: ["--trust-workspace"],
  pi: { args: ["--approve"], probe: ["--help"], probeMentions: "--approve" }
} as const

export const makeFlagSupport = (timeoutMs = 3000): FlagSupport => {
  const cache = new Map<
    string,
    { readonly identity: string | undefined; readonly supported: Promise<boolean> }
  >()
  return (command, flag, env) => {
    const key = `${command}\0${flag.args.join("\0")}`
    const identity = binaryIdentity(command)
    const cached = cache.get(key)
    if (cached !== undefined && cached.identity === identity) return cached.supported
    const supported = new Promise<boolean>((resolve) => {
      execFile(
        command,
        [...flag.probe],
        { cwd: homedir(), env, timeout: timeoutMs },
        (error, stdout, stderr) => {
          const mentioned =
            flag.probeMentions === undefined || `${stdout}${stderr}`.includes(flag.probeMentions)
          resolve(error === null && mentioned)
        }
      )
    })
    cache.set(key, { identity, supported })
    return supported
  }
}

const supportsFlag = makeFlagSupport()

export const trustArgs = async (
  environment: ProviderEnvironment,
  command: string,
  flag: TrustFlag | undefined,
  env: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  if (flag === undefined) return []
  return (await (environment.supportsFlag ?? supportsFlag)(command, flag, env)) ? flag.args : []
}
