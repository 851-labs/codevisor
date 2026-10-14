import { execFileSync } from "node:child_process"
import { accessSync, constants, statSync } from "node:fs"
import { delimiter, join } from "node:path"

import { binaryIdentity, OPENCODE_INSTALL_PATH } from "@codevisor/agent-runtime"

export interface OpenCodeBinaryDeps {
  readonly candidates?: (env: NodeJS.ProcessEnv) => ReadonlyArray<string>
  readonly readVersion?: (path: string) => string | undefined
}

/* v8 ignore start */
const executable = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK)
    return statSync(path).isFile()
  } catch {
    return false
  }
}

const defaultCandidates = (env: NodeJS.ProcessEnv): ReadonlyArray<string> => {
  const onPath = (env.PATH ?? "").split(delimiter).flatMap((directory) => {
    const path = join(directory, "opencode")
    return directory.length > 0 && executable(path) ? [path] : []
  })
  const installed =
    env.HOME === undefined ? undefined : OPENCODE_INSTALL_PATH.replace(/^~/, env.HOME)
  return installed !== undefined && executable(installed) ? [...onPath, installed] : onPath
}

const versions = new Map<
  string,
  { readonly identity: string | undefined; readonly output?: string }
>()

const defaultReadVersion = (path: string): string | undefined => {
  const identity = binaryIdentity(path)
  const cached = versions.get(path)
  if (cached !== undefined && identity !== undefined && cached.identity === identity) {
    return cached.output
  }
  let output: string | undefined
  try {
    output = execFileSync(path, ["--version"], { encoding: "utf8", timeout: 5_000 })
  } catch {
    output = undefined
  }
  versions.set(path, { identity, ...(output === undefined ? {} : { output }) })
  return output
}
/* v8 ignore stop */

const parts = (output: string | undefined): ReadonlyArray<number> | undefined => {
  const match = output?.match(/\bv?(\d+)\.(\d+)\.(\d+)/)
  return match === null || match === undefined ? undefined : match.slice(1, 4).map(Number)
}

const newer = (left: ReadonlyArray<number>, right: ReadonlyArray<number>): boolean => {
  for (let index = 0; index < 3; index += 1) {
    if (left[index]! !== right[index]!) return left[index]! > right[index]!
  }
  return false
}

export const makeOpenCodeLocator =
  (deps: OpenCodeBinaryDeps = {}) =>
  (env: NodeJS.ProcessEnv): string | undefined => {
    const candidates = [...new Set((deps.candidates ?? defaultCandidates)(env))]
    const readVersion = deps.readVersion ?? defaultReadVersion
    let best: { readonly path: string; readonly version?: ReadonlyArray<number> } | undefined
    for (const path of candidates) {
      const version = parts(readVersion(path))
      if (best === undefined) {
        best = { path, ...(version === undefined ? {} : { version }) }
      } else if (
        version !== undefined &&
        (best.version === undefined || newer(version, best.version))
      ) {
        best = { path, version }
      }
    }
    return best?.path
  }
