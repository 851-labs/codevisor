import { accessSync, constants } from "node:fs"

/// How politely a command should compete for CPU and disk.
///
/// Archiving a workspace snapshots and deletes a whole checkout, often with a
/// large `node_modules`. At normal priority that I/O competes head-on with the
/// user's editor, builds, and agents, which is what made archiving feel like
/// it froze the machine.
///
/// - `utility`: work someone may be waiting on (a snapshot must finish before
///   an unarchive can proceed), so it is throttled but still makes progress.
/// - `background`: work nobody waits on (deleting trashed files), which the
///   OS may defer as long as it likes.
export type CommandPriority = "utility" | "background"

export interface PriorityHost {
  readonly platform: NodeJS.Platform
  readonly isExecutable: (path: string) => boolean
}

export interface PrioritizedCommand {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

export type PriorityWrapper = (
  command: string,
  args: ReadonlyArray<string>,
  priority?: CommandPriority
) => PrioritizedCommand

const taskpolicyPath = "/usr/sbin/taskpolicy"
const nicePaths = ["/usr/bin/nice", "/bin/nice"]
const ionicePaths = ["/usr/bin/ionice", "/bin/ionice"]

export const systemPriorityHost: PriorityHost = {
  platform: process.platform,
  isExecutable: (path) => {
    try {
      accessSync(path, constants.X_OK)
      return true
    } catch {
      return false
    }
  }
}

/// Resolves the platform's priority tools once, then wraps commands with them.
/// When no tool exists the command runs plainly: a slower archive is better
/// than one that cannot start.
export const makePriorityWrapper = (host: PriorityHost): PriorityWrapper => {
  const taskpolicy = host.platform === "darwin" && host.isExecutable(taskpolicyPath)
  const nice = host.platform === "linux" ? nicePaths.find(host.isExecutable) : undefined
  const ionice = nice === undefined ? undefined : ionicePaths.find(host.isExecutable)
  return (command, args, priority) => {
    if (priority === undefined) return { command, args }
    if (taskpolicy) {
      // `-c utility` applies the utility QoS clamp (CPU and I/O); `-b` marks
      // the process as background, the most deferrable tier macOS offers.
      const policy = priority === "utility" ? ["-c", "utility"] : ["-b"]
      return { command: taskpolicyPath, args: [...policy, command, ...args] }
    }
    if (nice !== undefined) {
      const niceArgs = ["-n", priority === "utility" ? "10" : "19", command, ...args]
      if (priority === "background" && ionice !== undefined) {
        // The idle I/O class only gets disk time nobody else wants.
        return { command: ionice, args: ["-c3", nice, ...niceArgs] }
      }
      return { command: nice, args: niceArgs }
    }
    return { command, args }
  }
}

let systemWrapper: PriorityWrapper | undefined

/// Wraps a command for the current machine, probing for the tools on first use.
/// `CODEVISOR_COMMAND_PRIORITY=normal` runs everything at normal priority: the
/// test suites set it, because throttled git on a busy runner turns ordinary
/// tests into timeouts, and the wrapping itself is tested with injected hosts.
export const withPriority: PriorityWrapper = (command, args, priority) => {
  if (process.env.CODEVISOR_COMMAND_PRIORITY === "normal") return { command, args }
  systemWrapper ??= makePriorityWrapper(systemPriorityHost)
  return systemWrapper(command, args, priority)
}
