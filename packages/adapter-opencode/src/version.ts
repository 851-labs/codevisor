import { execFile } from "node:child_process"
import { promisify } from "node:util"

import { binaryIdentity } from "@codevisor/agent-runtime"

/// OpenCode's major version, from `opencode --version`: "opencode v2.0.24"
/// on OpenCode 2, a bare "1.18.34" on OpenCode 1. Cached per binary until it
/// changes, so an upgrade in place is noticed.

export interface OpenCodeVersionProbeDeps {
  readonly run?: (command: string) => Promise<string>
  readonly identity?: (command: string) => string | undefined
}

const runVersion = async (command: string) =>
  (await promisify(execFile)(command, ["--version"], { timeout: 5_000 })).stdout

export const parseOpenCodeMajorVersion = (output: string): number | undefined => {
  const match = output.match(/\bv?(\d+)\.\d+\.\d+/)
  return match?.[1] === undefined ? undefined : Number(match[1])
}

export const makeOpenCodeVersionProbe = (deps: OpenCodeVersionProbeDeps = {}) => {
  const run = deps.run ?? runVersion
  const identity = deps.identity ?? binaryIdentity
  const cache = new Map<
    string,
    { readonly identity: string | undefined; readonly major: Promise<number | undefined> }
  >()
  return async (command: string): Promise<number | undefined> => {
    const current = identity(command)
    const cached = cache.get(command)
    // A command that can't be stat'd (a bare name) is asked every time.
    if (cached !== undefined && current !== undefined && cached.identity === current) {
      return cached.major
    }
    const major = run(command).then(parseOpenCodeMajorVersion, () => undefined)
    cache.set(command, { identity: current, major })
    return major
  }
}
