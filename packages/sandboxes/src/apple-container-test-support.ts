import type {
  ContainerCli,
  ContainerHost,
  ContainerHostHardware,
  ContainerRunOptions
} from "./apple-container-host.js"
import type { ExecResult } from "./provider.js"

export interface FakeContainer {
  readonly id: string
  state: string
  readonly labels: Readonly<Record<string, string>>
  readonly memoryGiB: number
}

export interface FakeContainerSetup {
  readonly cli?: ContainerCli
  readonly installed?: boolean
  readonly containers?: FakeContainer[]
  readonly images?: string[]
  readonly systemRunning?: boolean
  readonly macOS?: string
  readonly freeGiB?: number
  readonly hardware?: ContainerHostHardware
  readonly execFailures?: number
  readonly failing?: string
  readonly onScript?: (script: string, options: ContainerRunOptions | undefined) => ExecResult
}

const gib = 1024 ** 3

export const ok = (stdout = ""): ExecResult => ({ exitCode: 0, stdout, stderr: "" })

export const fakeContainerHost = (setup: FakeContainerSetup = {}) => {
  const containers = setup.containers ?? []
  const images = setup.images ?? []
  const commands: string[] = []
  const sleeps: number[] = []
  const contexts: string[] = []
  let installed = setup.installed ?? true
  let systemRunning = setup.systemRunning ?? true
  let execFailures = setup.execFailures ?? 0
  const cli = setup.cli ?? { binary: "/usr/local/bin/container", version: "1.3.1" }
  const find = (id: string | undefined) => containers.find((each) => each.id === id)
  const respond = (args: ReadonlyArray<string>, options?: ContainerRunOptions): ExecResult => {
    const [command, first] = args
    const key = args.slice(0, 2).join(" ")
    if (key === setup.failing || command === setup.failing) {
      return { exitCode: 1, stdout: "", stderr: `${key} broke\n` }
    }
    if (key === "system status") {
      return systemRunning
        ? ok(JSON.stringify({ status: "running" }))
        : { exitCode: 1, stdout: "", stderr: "" }
    }
    if (key === "system start") systemRunning = true
    if (command === "list") return ok(JSON.stringify(containers.map(asJson)))
    if (key === "image list")
      return ok(JSON.stringify(images.map((name) => ({ configuration: { name } }))))
    if (key === "image pull") images.push(args.at(-1) ?? "")
    if (key === "image delete") remove(images, images.indexOf(args.at(-1) ?? ""))
    if (command === "build") images.push(args[args.indexOf("-t") + 1] ?? "")
    if (command === "run") containers.push(runContainer(args))
    if (command === "start") {
      const container = find(first)
      if (container !== undefined) container.state = "running"
    }
    if (command === "delete")
      remove(
        containers,
        containers.findIndex((each) => each.id === args.at(-1))
      )
    if (command === "exec" && args.at(-1) === "true" && execFailures > 0) {
      execFailures -= 1
      return { exitCode: 1, stdout: "", stderr: "" }
    }
    if (command === "exec" && args.includes("-c"))
      return setup.onScript?.(args.at(-1) ?? "", options) ?? ok()
    return ok()
  }
  const host: ContainerHost = {
    locate: () => Promise.resolve(installed ? cli : undefined),
    install: (log) => {
      commands.push("install")
      log("Installed container")
      installed = true
      return Promise.resolve()
    },
    run: (args, options) => {
      commands.push(args.join(" "))
      return Promise.resolve(respond(args, options))
    },
    macOSVersion: () => Promise.resolve(setup.macOS ?? "26.1"),
    freeDiskBytes: () => Promise.resolve((setup.freeGiB ?? 90) * gib),
    hardware: () => setup.hardware ?? { cpus: 10, memoryBytes: 36 * gib },
    buildContext: (containerfile) => {
      contexts.push(containerfile)
      return Promise.resolve({
        file: "/tmp/build/Containerfile",
        directory: "/tmp/build",
        dispose: () => {
          commands.push("dispose context")
          return Promise.resolve()
        }
      })
    },
    sleep: (ms) => {
      sleeps.push(ms)
      return Promise.resolve()
    }
  }
  return { host, containers, images, commands, sleeps, contexts }
}

const remove = (items: unknown[], index: number): void => {
  if (index >= 0) items.splice(index, 1)
}

const runContainer = (args: ReadonlyArray<string>): FakeContainer => {
  const labels = args.flatMap((arg, index) => (args[index - 1] === "--label" ? [arg] : []))
  const memory = args[args.indexOf("--memory") + 1] ?? "0g"
  return {
    id: args[args.indexOf("--name") + 1] ?? "",
    state: "running",
    labels: Object.fromEntries(labels.map((label) => label.split("="))),
    memoryGiB: Number.parseInt(memory, 10)
  }
}

const asJson = (container: FakeContainer) => ({
  configuration: {
    id: container.id,
    ...(Object.keys(container.labels).length === 0 ? {} : { labels: container.labels }),
    resources: { memoryInBytes: container.memoryGiB * gib }
  },
  status: { state: container.state }
})
