import { Schema } from "effect"

import {
  SandboxProviderError,
  type ExecResult,
  type OutputStream,
  type ProvisionProgress
} from "./provider.js"

export interface ContainerRunOptions {
  readonly stdin?: string
  readonly timeoutMs?: number
  readonly onOutput?: (stream: OutputStream, text: string) => void
}

export interface ContainerCli {
  readonly binary: string
  readonly version: string
}

export interface ContainerHostHardware {
  readonly cpus: number
  readonly memoryBytes: number
}

export interface BuildContext {
  readonly file: string
  readonly directory: string
  readonly dispose: () => Promise<void>
}

export interface ContainerHost {
  readonly locate: () => Promise<ContainerCli | undefined>
  readonly install: (log: (line: string) => void) => Promise<void>
  readonly run: (args: ReadonlyArray<string>, options?: ContainerRunOptions) => Promise<ExecResult>
  readonly macOSVersion: () => Promise<string>
  readonly freeDiskBytes: () => Promise<number>
  readonly hardware: () => ContainerHostHardware
  readonly buildContext: (containerfile: string) => Promise<BuildContext>
  readonly sleep: (ms: number) => Promise<void>
}

export interface ListedContainer {
  readonly id: string
  readonly state: string
  readonly labels: Readonly<Record<string, string>>
  readonly memoryBytes: number
}

export const CONTAINER_PLATFORM = "linux/arm64"

const systemStartTimeoutMs = 30 * 60 * 1000

const ContainerJson = Schema.Struct({
  configuration: Schema.Struct({
    id: Schema.String,
    labels: Schema.optional(Schema.Record(Schema.String, Schema.String)),
    resources: Schema.Struct({ memoryInBytes: Schema.Number })
  }),
  status: Schema.Struct({ state: Schema.String })
})
const decodeContainers = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Array(ContainerJson))
)

const ImageJson = Schema.Struct({ configuration: Schema.Struct({ name: Schema.String }) })
const decodeImages = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Array(ImageJson)))

const decodeSystemStatus = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Struct({ status: Schema.String }))
)

export type ContainerCommands = ReturnType<typeof containerCommands>

export const containerCommands = (host: ContainerHost) => {
  const must = async (
    args: ReadonlyArray<string>,
    options?: ContainerRunOptions
  ): Promise<string> => {
    const result = await host.run(args, options)
    if (result.exitCode !== 0) throw containerFailure(args, result)
    return result.stdout
  }
  const systemRunning = async (): Promise<boolean> => {
    const result = await host.run(["system", "status", "--format", "json"])
    return result.exitCode === 0 && decodeSystemStatus(result.stdout).status === "running"
  }
  const containers = async (): Promise<ReadonlyArray<ListedContainer>> =>
    decodeContainers(await must(["list", "--all", "--format", "json"])).map(listed)
  return {
    must,
    systemRunning,
    containers,
    running: async (): Promise<ReadonlyArray<ListedContainer>> =>
      (await containers()).filter((container) => container.state === "running"),
    images: async (): Promise<ReadonlyArray<string>> =>
      decodeImages(await must(["image", "list", "--format", "json"])).map(
        (image) => image.configuration.name
      ),
    ensureSystem: async (progress: ProvisionProgress): Promise<void> => {
      if (await systemRunning()) return

      progress.log("container system start --enable-kernel-install")
      await must(["system", "start", "--enable-kernel-install"], {
        timeoutMs: systemStartTimeoutMs,
        onOutput: progress.output
      })
    },
    remove: async (id: string): Promise<void> => {
      await host.run(["delete", "--force", id])
    }
  }
}

export const containerFailure = (
  args: ReadonlyArray<string>,
  result: ExecResult
): SandboxProviderError =>
  new SandboxProviderError(
    "apple-container",
    `container ${args.join(" ")} failed (exit ${result.exitCode}): ${result.stderr.trim()}`
  )

const listed = (container: typeof ContainerJson.Type): ListedContainer => ({
  id: container.configuration.id,
  state: container.status.state,
  labels: container.configuration.labels ?? {},
  memoryBytes: container.configuration.resources.memoryInBytes
})
