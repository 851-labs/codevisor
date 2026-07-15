import { existsSync, mkdirSync, renameSync, rmSync } from "node:fs"
import { dirname, join } from "node:path"

/// Filesystem operations `installRuntime` performs, injectable for tests
/// (rename failures are otherwise impossible to simulate portably).
export interface InstallFsOperations {
  readonly exists: (path: string) => boolean
  readonly makeDirectory: (path: string) => void
  readonly rename: (from: string, to: string) => void
  readonly removeRecursive: (path: string) => void
}

export const defaultInstallFsOperations: InstallFsOperations = {
  exists: existsSync,
  makeDirectory: (path) => mkdirSync(path, { recursive: true }),
  rename: renameSync,
  removeRecursive: (path) => rmSync(path, { recursive: true, force: true })
}

/// Resolves the packaged install root (the directory holding main.js,
/// VERSION, and bin/node) from the running entrypoint, so self-update
/// replaces whatever install this process actually started from —
/// /opt/codevisor for root installs, ~/.codevisor/server for user installs.
/// Dev checkouts (apps/server/dist/main.js) don't look like runtime roots and
/// resolve to undefined, which skips the install swap.
export const resolveInstallRoot = (
  entrypoint: string | undefined,
  exists: (path: string) => boolean = existsSync
): string | undefined => {
  if (entrypoint === undefined || entrypoint.length === 0) {
    return undefined
  }
  const root = dirname(entrypoint)
  const marks = [join(root, "VERSION"), join(root, "main.js"), join(root, "bin", "node")]
  return marks.every((mark) => exists(mark)) ? root : undefined
}

export type RestartPlan =
  | { readonly kind: "systemd"; readonly unit: string; readonly userManager: boolean }
  | { readonly kind: "handoff" }

/// Decides how the replacement server starts after an update. Under systemd
/// (INVOCATION_ID is stamped on every unit-spawned process) the legacy
/// detached-handoff child dies with the unit's cgroup when the main process
/// exits, and a clean exit is final for Restart=on-failure units — so the
/// update must ask systemd itself to restart the service. install.sh creates
/// exactly two shapes: a system unit running as root and a --user unit, so
/// the effective uid picks the manager.
export const planRestart = (env: NodeJS.ProcessEnv, effectiveUid: number): RestartPlan => {
  const invocationId = env.INVOCATION_ID ?? ""
  if (invocationId.length === 0) {
    return { kind: "handoff" }
  }
  return {
    kind: "systemd",
    unit: "codevisor-server.service",
    userManager: effectiveUid !== 0
  }
}

/// Swaps a freshly extracted runtime into the install root. The new runtime
/// is extracted into a sibling directory (same filesystem, so the swap is a
/// pair of renames), the old root is moved aside and removed only after the
/// swap succeeds; a failed swap restores it. The running process keeps its
/// already-open files (POSIX inode semantics), so replacing the tree under it
/// is safe.
export const installRuntime = async (options: {
  readonly installRoot: string
  readonly extract: (destination: string) => Promise<void>
  readonly fs?: InstallFsOperations
}): Promise<void> => {
  const fs = options.fs ?? defaultInstallFsOperations
  const next = `${options.installRoot}.next`
  const previous = `${options.installRoot}.previous`

  fs.removeRecursive(next)
  fs.makeDirectory(next)
  await options.extract(next)
  if (!fs.exists(join(next, "main.js")) || !fs.exists(join(next, "bin", "node"))) {
    fs.removeRecursive(next)
    throw new Error(`Extracted runtime at ${next} is incomplete`)
  }

  fs.removeRecursive(previous)
  fs.rename(options.installRoot, previous)
  try {
    fs.rename(next, options.installRoot)
  } catch (error) {
    // Put the old install back so the machine still has a bootable server.
    fs.rename(previous, options.installRoot)
    throw error
  }
  fs.removeRecursive(previous)
}
