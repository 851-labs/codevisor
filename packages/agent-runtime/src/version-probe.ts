import { execFile } from "node:child_process"
import { statSync } from "node:fs"

/// Async `--version` probing for detected harness binaries. Readiness checks
/// are synchronous, so versions come from this cache: environment refreshes
/// (server boot and the client's "Detect again") probe and await, and
/// discovery reads whatever the cache holds.

export interface VersionProberOptions {
  /// Returns the binary's --version output; defaults to `execFile` with a
  /// hard timeout (a wedged CLI must not stall discovery forever). Receives
  /// the runtime's resolved environment: npm-installed CLIs are node scripts
  /// whose `#!/usr/bin/env node` shebang needs the resolved PATH, which a
  /// service-launched server's own environment does not have.
  readonly readVersionOutput?: (path: string, env: NodeJS.ProcessEnv) => Promise<string>
  /// Modification time used to invalidate cache entries when a binary is
  /// upgraded in place; defaults to `statSync`.
  readonly modifiedTime?: (path: string) => number | undefined
  readonly timeoutMs?: number
}

export interface VersionProber {
  /// Cached version for a binary path; undefined until a probe completes (or
  /// when the binary reports nothing parseable).
  readonly get: (path: string) => string | undefined
  /// Probes the given binaries with the given environment, skipping
  /// unchanged cache entries and sharing in-flight probes. Resolves when
  /// every probe settles; never rejects.
  readonly probe: (paths: ReadonlyArray<string>, env?: NodeJS.ProcessEnv) => Promise<void>
}

/// First semver-ish token in the output ("claude 2.1.5 (Claude Code)" → 2.1.5).
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
  const modifiedTime =
    options.modifiedTime ??
    ((path: string) => {
      try {
        return statSync(path).mtimeMs
      } catch {
        return undefined
      }
    })

  const cache = new Map<
    string,
    { readonly mtime: number | undefined; readonly version: string | undefined }
  >()
  const inflight = new Map<string, Promise<void>>()

  const probeOne = (path: string, env: NodeJS.ProcessEnv): Promise<void> => {
    const existing = inflight.get(path)
    if (existing !== undefined) return existing
    const mtime = modifiedTime(path)
    const cached = cache.get(path)
    if (cached !== undefined && cached.mtime === mtime) return Promise.resolve()
    const task = readVersionOutput(path, env)
      .then((output) => {
        cache.set(path, { mtime, version: parseVersionOutput(output) })
      })
      .catch(() => {
        cache.set(path, { mtime, version: undefined })
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
