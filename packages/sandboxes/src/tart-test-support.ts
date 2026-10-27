import type { ExecResult } from "./provider.js"
import type { TartHost, TartRunOptions } from "./tart-vm.js"

export interface FakeVm {
  Name: string
  State: string
  readonly OS: string
}

export interface FakeTartSetup {
  readonly vms?: FakeVm[]
  readonly freeGiB?: number
  readonly cloneOS?: string
  readonly agentFailures?: number
  readonly failing?: string
  readonly onScript?: (script: string, options: TartRunOptions | undefined) => ExecResult
  readonly copyExit?: number
}

const gib = 1024 ** 3

export const result = (stdout: string, exitCode = 0): ExecResult => ({
  exitCode,
  stdout,
  stderr: ""
})

export const fakeTart = (setup: FakeTartSetup = {}) => {
  const vms = setup.vms ?? []
  const commands: string[] = []
  const sleeps: number[] = []
  let agentFailures = setup.agentFailures ?? 0
  const find = (name: string | undefined) => vms.find((vm) => vm.Name === name)
  const respond = (args: ReadonlyArray<string>, options?: TartRunOptions): ExecResult => {
    const [command, first, second] = args
    if (command === setup.failing) return { exitCode: 1, stdout: "", stderr: `${command} broke\n` }
    if (command === "clone")
      vms.push({ Name: second ?? "", State: "stopped", OS: setup.cloneOS ?? "darwin" })
    if (command === "list")
      return result(JSON.stringify(vms.map(({ Name, State }) => ({ Name, State }))))
    if (command === "get") return result(JSON.stringify({ OS: find(first)?.OS }))
    if (command === "ip") return result("192.168.64.7\n")
    if (command === "stop") {
      const vm = find(first)
      if (vm !== undefined) vm.State = "stopped"
    }
    if (command === "rename") {
      const vm = find(first)
      if (vm !== undefined) vm.Name = second ?? ""
    }
    const index = vms.findIndex((vm) => vm.Name === first)
    if (command === "delete" && index >= 0) vms.splice(index, 1)
    if (command === "exec" && args.at(-1) === "true" && agentFailures > 0) {
      agentFailures -= 1
      return result("", 1)
    }
    if (command === "exec" && args.includes("-c"))
      return setup.onScript?.(args.at(-1) ?? "", options) ?? result("")
    return result("")
  }
  const host: TartHost = {
    run: (args, options) => {
      commands.push(args.join(" "))
      return Promise.resolve(respond(args, options))
    },
    copyIn: (vm, source, destination) => {
      commands.push(`copyIn ${vm} ${source} ${destination}`)
      return Promise.resolve({
        exitCode: setup.copyExit ?? 0,
        stdout: "",
        stderr: "tar: broken pipe\n"
      })
    },
    start: (args) => {
      commands.push(`start ${args.join(" ")}`)
      const vm = find(args.at(-1))
      if (vm !== undefined) vm.State = "running"
    },
    freeDiskBytes: () => Promise.resolve((setup.freeGiB ?? 90) * gib),
    sleep: (ms) => {
      sleeps.push(ms)
      return Promise.resolve()
    }
  }
  return { host, vms, commands, sleeps }
}
