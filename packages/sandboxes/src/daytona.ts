import { randomUUID } from "node:crypto"

import { shellQuote } from "./bootstrap.js"
import {
  numberField,
  numberValue,
  optionalString,
  secretField,
  stringValue,
  textField,
  urlField,
  type SandboxFieldValues
} from "./fields.js"
import { pauseAfterField, type SandboxPausing } from "./pausing.js"
import type {
  ExecResult,
  ProviderMachineState,
  SandboxAccountIdentity,
  SandboxAdapter,
  SandboxProvider,
  SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

export const DAYTONA_DEFAULT_API_URL = "https://app.daytona.io/api"

export const DAYTONA_SETUP_COMMANDS: ReadonlyArray<string> = [
  "apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git sudo procps && rm -rf /var/lib/apt/lists/*"
]

export const DAYTONA_DEFINITION: SandboxProviderDefinition = {
  id: "daytona",
  displayName: "Daytona",
  sandboxNoun: "Daytona sandbox",
  platform: "linux",
  tested: false,
  accountFields: [
    secretField("apiKey", "API key", {
      required: true,
      help: "Create one in the Daytona dashboard under API Keys with the write:sandboxes and delete:sandboxes permissions."
    }),
    urlField("apiUrl", "API URL", {
      default: DAYTONA_DEFAULT_API_URL,
      help: "Change this only for a self-hosted Daytona."
    }),
    textField("target", "Region", {
      placeholder: "us",
      help: "us or eu. Leave empty for your organization's default region."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      default: "debian:bookworm-slim",
      help: "A public Debian or Ubuntu image with a version tag. Codevisor adds curl, git and sudo."
    }),
    textField("snapshot", "Snapshot", {
      help: "A Daytona snapshot to start from instead of the image. CPU, memory and disk then come from the snapshot."
    }),
    numberField("cpu", "CPUs", { default: 2, min: 1, max: 4 }),
    numberField("memoryGiB", "Memory (GiB)", { default: 4, min: 1, max: 8 }),
    numberField("diskGiB", "Disk (GiB)", { default: 10, min: 1, max: 10 }),
    pauseAfterField({ never: true })
  ]
}

export interface DaytonaResources {
  readonly cpu: number
  readonly memory: number
  readonly disk: number
}

export type DaytonaSource =
  | {
      readonly kind: "image"
      readonly image: string
      readonly setupCommands: ReadonlyArray<string>
      readonly resources: DaytonaResources
    }
  | { readonly kind: "snapshot"; readonly snapshot: string }

export interface DaytonaCreateRequest {
  readonly source: DaytonaSource
  readonly labels: Record<string, string>
  readonly autoStopMinutes: number
}

export interface DaytonaSandboxInfo {
  readonly id: string
  readonly state?: string
  readonly labels: Readonly<Record<string, string>>
}

export interface DaytonaClient {
  readonly create: (
    request: DaytonaCreateRequest,
    onLog: (line: string) => void
  ) => Promise<DaytonaSandboxInfo>
  readonly upload: (sandboxId: string, path: string, content: string) => Promise<void>
  readonly run: (sandboxId: string, command: string, timeoutMs: number) => Promise<ExecResult>
  readonly info: (sandboxId: string) => Promise<DaytonaSandboxInfo | undefined>
  readonly start: (sandboxId: string) => Promise<void>
  readonly stop: (sandboxId: string) => Promise<void>
  readonly remove: (sandboxId: string) => Promise<void>
  readonly list: (labels: Record<string, string>) => Promise<ReadonlyArray<DaytonaSandboxInfo>>
  readonly email: () => Promise<string | undefined>
}

export interface DaytonaCredentials {
  readonly apiKey: string
  readonly apiUrl: string
  readonly target?: string
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const millisecondsPerSecond = 1000
const neverAutoStop = 0

export const daytonaAdapter = (
  connectClient: (credentials: DaytonaCredentials) => DaytonaClient
): SandboxAdapter => {
  const clientFor = (account: SandboxFieldValues) => connectClient(credentialsFor(account))
  return {
    definition: DAYTONA_DEFINITION,
    connect: (account) => makeDaytonaProvider(clientFor(account)),
    verify: async (account) => {
      const client = clientFor(account)
      await client.list(ownerFilter("codevisor-verify"))
      return identityFor(await client.email())
    }
  }
}

export const makeDaytonaProvider = (
  client: DaytonaClient,
  newId: () => string = randomUUID
): SandboxProvider => ({
  definition: DAYTONA_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options, progress) => {
    const sandbox = await client.create(
      {
        source: sourceFor(options),
        labels: tagsToRecord(spec.tags),
        autoStopMinutes: neverAutoStop
      },
      (line) => progress?.log(line)
    )
    return { providerMachineId: sandbox.id, platform: "linux" }
  },
  exec: async (sandboxId, request) => {
    const timeoutMs = request.timeoutMs ?? defaultExecTimeoutMs
    const input = await uploadedStdin(client, sandboxId, request.stdin, newId)
    return client.run(sandboxId, rootCommand(request.script, input, timeoutMs), timeoutMs)
  },
  status: async (sandboxId) => ({ state: stateFor(await client.info(sandboxId)) }),
  resume: (sandboxId) => client.start(sandboxId),
  destroy: (sandboxId) => client.remove(sandboxId),
  list: async (owner) =>
    (await client.list(ownerFilter(owner))).flatMap((sandbox) =>
      listedMachine(sandbox.id, sandbox.labels)
    ),
  pausing: daytonaPausing(client)
})

const daytonaPausing = (client: DaytonaClient): SandboxPausing => ({
  pause: async (sandboxId) => {
    await client.stop(sandboxId)
    return { providerMachineId: sandboxId }
  },
  wake: async (paused) => {
    await client.start(paused.providerMachineId)
    return { providerMachineId: paused.providerMachineId }
  }
})

const credentialsFor = (account: SandboxFieldValues): DaytonaCredentials => {
  const target = optionalString(account, "target")
  return {
    apiKey: stringValue(account, "apiKey"),
    apiUrl: optionalString(account, "apiUrl") ?? DAYTONA_DEFAULT_API_URL,
    ...(target === undefined ? {} : { target })
  }
}

const sourceFor = (options: SandboxFieldValues): DaytonaSource => {
  const snapshot = optionalString(options, "snapshot")
  if (snapshot !== undefined) return { kind: "snapshot", snapshot }

  return {
    kind: "image",
    image: stringValue(options, "image"),
    setupCommands: DAYTONA_SETUP_COMMANDS,
    resources: {
      cpu: numberValue(options, "cpu", 2),
      memory: numberValue(options, "memoryGiB", 4),
      disk: numberValue(options, "diskGiB", 10)
    }
  }
}

interface ScriptInput {
  readonly path: string
  readonly cleanup: ReadonlyArray<string>
}

const uploadedStdin = async (
  client: DaytonaClient,
  sandboxId: string,
  stdin: string | undefined,
  newId: () => string
): Promise<ScriptInput> => {
  if (stdin === undefined) return { path: "/dev/null", cleanup: [] }

  const path = `/tmp/codevisor-stdin-${newId()}`
  await client.upload(sandboxId, path, stdin)
  return { path, cleanup: [`rm -f ${shellQuote(path)}`] }
}

const rootCommand = (script: string, input: ScriptInput, timeoutMs: number): string => {
  const seconds = Math.max(1, Math.ceil(timeoutMs / millisecondsPerSecond))
  const lines = [
    'as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }',
    `as_root timeout -s KILL ${seconds} sh -c ${shellQuote(script)} <${shellQuote(input.path)}`,
    "status=$?",
    ...input.cleanup,
    "exit $status"
  ]
  return `sh -c ${shellQuote(lines.join("\n"))}`
}

const machineStates: Readonly<Record<string, ProviderMachineState>> = {
  started: "running",
  stopped: "stopped",
  archived: "stopped",
  paused: "stopped",
  destroyed: "gone",
  destroying: "gone",
  error: "gone",
  build_failed: "gone"
}

const stateFor = (sandbox: DaytonaSandboxInfo | undefined): ProviderMachineState => {
  if (sandbox === undefined) return "gone"

  return machineStates[sandbox.state ?? ""] ?? "starting"
}

const identityFor = (email: string | undefined): SandboxAccountIdentity =>
  email === undefined ? {} : { identity: email }
