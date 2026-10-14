import { execFile } from "node:child_process"
import { statSync } from "node:fs"

export interface VersionProberOptions {
  readonly readVersionOutput?: (path: string, env: NodeJS.ProcessEnv) => Promise<string>
  readonly identity?: (path: string) => string | undefined
  readonly timeoutMs?: number
}

export interface VersionProber {
  readonly get: (path: string) => string | undefined
  readonly probe: (paths: ReadonlyArray<string>, env?: NodeJS.ProcessEnv) => Promise<void>
}

export const binaryIdentity = (path: string): string | undefined => {
  try {
    const stats = statSync(path, { throwIfNoEntry: false })
    return stats === undefined ? undefined : `${stats.dev}:${stats.ino}:${stats.ctimeMs}`
  } catch {
    return undefined
  }
}

export const parseVersionOutput = (output: string): string | undefined =>
  output.match(/\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?|\d+\.\d+/)?.[0]

export const makeVersionProber = (options: VersionProberOptions = {}): VersionProber => {
  const timeoutMs = options.timeoutMs ?? 3000
  const readVersionOutput =
    options.readVersionOutput ??
    ((path: string, env: NodeJS.ProcessEnv) =>
      new Promise<string>((resolve, reject) => {
        execFile(path, ["--version"], { timeout: timeoutMs, env }, (error, stdout, stderr) => {
          if (error === null) {
            resolve(`${stdout}\n${stderr}`)
          } else {
            reject(error)
          }
        })
      }))
  const identity = options.identity ?? binaryIdentity

  const cache = new Map<
    string,
    { readonly identity: string | undefined; readonly version: string | undefined }
  >()
  const inflight = new Map<string, Promise<void>>()

  const probeOne = (path: string, env: NodeJS.ProcessEnv): Promise<void> => {
    const existing = inflight.get(path)
    if (existing !== undefined) return existing
    const current = identity(path)
    const cached = cache.get(path)
    if (cached !== undefined && cached.identity === current) return Promise.resolve()
    const task = readVersionOutput(path, env)
      .then((output) => {
        cache.set(path, { identity: current, version: parseVersionOutput(output) })
      })
      .catch(() => {
        cache.set(path, { identity: current, version: undefined })
      })
      .finally(() => {
        inflight.delete(path)
      })
    inflight.set(path, task)
    return task
  }

  return {
    get: (path) => cache.get(path)?.version,
    probe: (paths, env = process.env) =>
      Promise.all([...new Set(paths)].map((path) => probeOne(path, env))).then(() => undefined)
  }
}
