import { accessSync, constants } from "node:fs"

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

export const makePriorityWrapper = (host: PriorityHost): PriorityWrapper => {
  const taskpolicy = host.platform === "darwin" && host.isExecutable(taskpolicyPath)
  const nice = host.platform === "linux" ? nicePaths.find(host.isExecutable) : undefined
  const ionice = nice === undefined ? undefined : ionicePaths.find(host.isExecutable)
  return (command, args, priority) => {
    if (priority === undefined) return { command, args }
    if (taskpolicy) {
      const policy = priority === "utility" ? ["-c", "utility"] : ["-b"]
      return { command: taskpolicyPath, args: [...policy, command, ...args] }
    }
    if (nice !== undefined) {
      const niceArgs = ["-n", priority === "utility" ? "10" : "19", command, ...args]
      if (priority === "background" && ionice !== undefined) {
        return { command: ionice, args: ["-c3", nice, ...niceArgs] }
      }
      return { command: nice, args: niceArgs }
    }
    return { command, args }
  }
}

let systemWrapper: PriorityWrapper | undefined

export const withPriority: PriorityWrapper = (command, args, priority) => {
  if (process.env.CODEVISOR_COMMAND_PRIORITY === "normal") return { command, args }
  systemWrapper ??= makePriorityWrapper(systemPriorityHost)
  return systemWrapper(command, args, priority)
}
