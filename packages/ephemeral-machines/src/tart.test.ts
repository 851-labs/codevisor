import { describe, expect, it } from "vitest"

import type { ExecResult } from "./provider.js"
import { makeTartProvider, vmName, type TartHost, type TartOptions } from "./tart.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const name = vmName(spec)
const options: TartOptions = {
  image: "ghcr.io/cirruslabs/macos-sonoma-base:latest",
  cpu: 4,
  memoryGiB: 8,
  minFreeDiskGiB: 40
}
const gib = 1024 ** 3

interface Vm {
  readonly Name: string
  State: string
  readonly OS: string
}

const result = (stdout: string, exitCode = 0): ExecResult => ({ exitCode, stdout, stderr: "" })
const ignoreOutput = () => undefined

const fakeTart = (setup: {
  readonly vms?: Vm[]
  readonly freeGiB?: number
  readonly cloneOS?: string
  readonly agentFailures?: number
  readonly failing?: string
}) => {
  const vms = setup.vms ?? []
  const commands: string[] = []
  const sleeps: number[] = []
  let agentFailures = setup.agentFailures ?? 0
  const respond = (args: ReadonlyArray<string>): ExecResult => {
    const [command, first] = args
    if (command === setup.failing) return { exitCode: 1, stdout: "", stderr: `${command} broke\n` }
    if (command === "clone")
      vms.push({ Name: args[2] ?? "", State: "stopped", OS: setup.cloneOS ?? "darwin" })
    if (command === "list")
      return result(JSON.stringify(vms.map(({ Name, State }) => ({ Name, State }))))
    if (command === "get")
      return result(JSON.stringify({ OS: vms.find((vm) => vm.Name === first)?.OS }))
    if (command === "ip") return result("192.168.64.7\n")
    if (command === "delete")
      vms.splice(
        vms.findIndex((vm) => vm.Name === first),
        1
      )
    if (command === "exec" && args.at(-1) === "true" && agentFailures > 0) {
      agentFailures -= 1
      return result("", 1)
    }
    return result("")
  }
  const host: TartHost = {
    run: (args) => {
      commands.push(args.join(" "))
      return Promise.resolve(respond(args))
    },
    start: (args) => {
      commands.push(`start ${args.join(" ")}`)
      const vm = vms.find((candidate) => candidate.Name === args.at(-1))
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

describe("Tart provider", () => {
  it("clones, sizes, boots headless and waits for the guest agent", async () => {
    const tart = fakeTart({ agentFailures: 2 })

    const created = await makeTartProvider(tart.host).create(spec, options)

    expect(created).toEqual({ providerMachineId: name, platform: "darwin" })
    expect(tart.commands).toEqual([
      `clone ${options.image} ${name}`,
      `get ${name} --format json`,
      "list --source local --format json",
      `set ${name} --cpu 4 --memory 8192`,
      `start run --no-graphics ${name}`,
      `ip ${name} --wait 180`,
      `exec ${name} true`,
      `exec ${name} true`,
      `exec ${name} true`
    ])
    expect(tart.sleeps).toEqual([2000, 2000])
  })

  it("refuses to start below the free disk floor before pulling anything", async () => {
    const tart = fakeTart({ freeGiB: 39.5 })

    await expect(makeTartProvider(tart.host).create(spec, options)).rejects.toThrow(
      "Only 39.5 GB of disk is free; Tart needs at least 40 GB to start a VM"
    )
    expect(tart.commands).toEqual([])
  })

  it("refuses a third running macOS VM and deletes the clone", async () => {
    const tart = fakeTart({
      vms: [
        { Name: "a", State: "running", OS: "darwin" },
        { Name: "b", State: "running", OS: "darwin" }
      ]
    })

    await expect(makeTartProvider(tart.host).create(spec, options)).rejects.toThrow(
      "macOS allows only 2 macOS VMs running at once on this Mac; stop one first"
    )
    expect(tart.vms.map((vm) => vm.Name)).toEqual(["a", "b"])
    expect(tart.commands.slice(-2)).toEqual([`stop ${name}`, `delete ${name}`])
  })

  it("lets a Linux image start beside two macOS VMs", async () => {
    const tart = fakeTart({
      cloneOS: "linux",
      vms: [
        { Name: "a", State: "running", OS: "darwin" },
        { Name: "b", State: "running", OS: "darwin" }
      ]
    })

    expect(await makeTartProvider(tart.host).create(spec, options)).toEqual({
      providerMachineId: name,
      platform: "linux"
    })
  })

  it("gives up and cleans up when the guest agent never answers", async () => {
    const tart = fakeTart({ agentFailures: 1000 })

    await expect(makeTartProvider(tart.host).create(spec, options)).rejects.toThrow(
      `The Tart guest agent in ${name} never answered`
    )
    expect(tart.sleeps).toHaveLength(60)
    expect(tart.vms).toEqual([])
  })

  it("resumes a stopped VM by booting it headless and waiting for the guest agent", async () => {
    const tart = fakeTart({ vms: [{ Name: name, State: "stopped", OS: "darwin" }] })

    await makeTartProvider(tart.host).resume?.(name)

    expect(tart.commands).toEqual([
      `start run --no-graphics ${name}`,
      `ip ${name} --wait 180`,
      `exec ${name} true`
    ])
    expect(tart.vms[0]?.State).toBe("running")
  })

  it("reports a failed tart command with its stderr", async () => {
    const tart = fakeTart({ failing: "clone" })

    await expect(makeTartProvider(tart.host).create(spec, options)).rejects.toThrow(
      `tart clone ${options.image} ${name} failed (exit 1): clone broke`
    )
  })

  it("runs scripts through the guest agent with stdin", async () => {
    const tart = fakeTart({})
    const calls: unknown[] = []
    const provider = makeTartProvider({
      ...tart.host,
      run: (args, runOptions) => {
        calls.push({ args, ...runOptions })
        return Promise.resolve(result("hi"))
      }
    })

    await provider.exec(name, { script: "id" })
    await provider.exec(name, { script: "cat", stdin: "x", timeoutMs: 5, onOutput: ignoreOutput })

    expect(calls).toEqual([
      { args: ["exec", "-i", name, "sh", "-c", "id"], stdin: "", timeoutMs: 600_000 },
      {
        args: ["exec", "-i", name, "sh", "-c", "cat"],
        stdin: "x",
        timeoutMs: 5,
        onOutput: ignoreOutput
      }
    ])
  })

  it("reports what it runs while creating, and when booting starts", async () => {
    const tart = fakeTart({})
    const events: string[] = []

    await makeTartProvider(tart.host).create(spec, options, {
      stage: (stage) => events.push(`stage ${stage}`),
      log: (line) => events.push(line)
    })

    expect(events).toEqual([
      `tart clone ${options.image} ${name}`,
      `tart set ${name} --cpu 4 --memory 8192`,
      "stage boot",
      `tart run --no-graphics ${name}`,
      "Waiting for an IP address",
      "Got 192.168.64.7",
      "Waiting for the guest agent",
      "The guest agent is ready"
    ])
  })

  it("reports status, lists owned VMs, serves VNC and deletes on destroy", async () => {
    const tart = fakeTart({
      vms: [
        { Name: name, State: "running", OS: "darwin" },
        { Name: "codevisor_device-b_m2", State: "stopped", OS: "darwin" },
        { Name: "codevisor_broken", State: "stopped", OS: "darwin" },
        { Name: "personal", State: "stopped", OS: "darwin" }
      ]
    })
    const provider = makeTartProvider(tart.host)

    expect(await provider.status(name)).toEqual({ state: "running" })
    expect(await provider.status("codevisor_device-b_m2")).toEqual({ state: "stopped" })
    expect(await provider.list("device-a")).toEqual([
      { providerMachineId: name, tags: { owner: "device-a", machine: "m1" } }
    ])
    expect(await provider.gui?.(name)).toEqual({ vncUrl: "vnc://192.168.64.7:5900" })

    await provider.destroy(name)

    expect(await provider.status(name)).toEqual({ state: "gone" })
  })
})
