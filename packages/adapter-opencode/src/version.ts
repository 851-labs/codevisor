import { execFile } from "node:child_process"
import { stat } from "node:fs/promises"
import { promisify } from "node:util"

/// OpenCode's major version, from `opencode --version`: "opencode v2.0.24"
/// on OpenCode 2, a bare "1.18.34" on OpenCode 1. Cached per binary and its
/// modification time, so an upgrade in place is noticed.

export interface OpenCodeVersionProbeDeps {
  readonly run?: (command: string) => Promise<string>
  readonly modified?: (command: string) => Promise<number>
}

const runVersion = async (command: string) =>
  (await promisify(execFile)(command, ["--version"], { timeout: 5_000 })).stdout

export const parseOpenCodeMajorVersion = (output: string): number | undefined => {
  const match = output.match(/\bv?(\d+)\.\d+\.\d+/)
  return match?.[1] === undefined ? undefined : Number(match[1])
}

export const makeOpenCodeVersionProbe = (deps: OpenCodeVersionProbeDeps = {}) => {
  const run = deps.run ?? runVersion
  const modified = deps.modified ?? (async (command: string) => (await stat(command)).mtimeMs)
  const cache = new Map<
    string,
    { readonly modified: number; readonly major: Promise<number | undefined> }
  >()
  return async (command: string): Promise<number | undefined> => {
    const current = await modified(command).catch(() => Number.NaN)
    const cached = cache.get(command)
    if (cached !== undefined && cached.modified === current) return cached.major
    const major = run(command).then(parseOpenCodeMajorVersion, () => undefined)
    cache.set(command, { modified: current, major })
    return major
  }
}
