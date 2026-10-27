import {
  numberField,
  numberValue,
  secretField,
  stringValue,
  textField,
  type SandboxFieldValues
} from "./fields.js"
import type {
  ExecResult,
  SandboxAdapter,
  SandboxProvider,
  SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

const defaultSetupCommands = [
  "RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git sudo procps && rm -rf /var/lib/apt/lists/*"
]

export const MODAL_APP_NAME = "codevisor-sandbox"

export const MODAL_DEFINITION: SandboxProviderDefinition = {
  id: "modal",
  displayName: "Modal",
  sandboxNoun: "Modal sandbox",
  platform: "linux",
  tested: true,
  accountFields: [
    textField("tokenId", "Token ID", { required: true, placeholder: "ak-…" }),
    secretField("tokenSecret", "Token secret", {
      required: true,
      placeholder: "as-…",
      help: "Create a token in Modal under Settings › API Tokens."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      default: "debian:bookworm-slim",
      help: "A public Debian or Ubuntu based image. Codevisor adds curl, git and sudo."
    }),
    numberField("cpu", "CPUs", { default: 2, min: 1, max: 64 }),
    numberField("memoryGiB", "Memory (GiB)", { default: 4, min: 1, max: 256 }),
    numberField("timeoutMinutes", "Lifetime (minutes)", { default: 1440, min: 5, max: 1440 })
  ]
}

export interface ModalSandboxRef {
  readonly sandboxId: string
  readonly tags: Readonly<Record<string, string>>
}

export interface ModalCreateRequest {
  readonly image: string
  readonly setupCommands: ReadonlyArray<string>
  readonly cpu: number
  readonly memoryMiB: number
  readonly timeoutMs: number
  readonly tags: Record<string, string>
}

export interface ModalClient {
  readonly create: (request: ModalCreateRequest) => Promise<string>
  readonly exec: (
    sandboxId: string,
    script: string,
    options: { readonly stdin?: string; readonly timeoutMs: number }
  ) => Promise<ExecResult>
  readonly isRunning: (sandboxId: string) => Promise<boolean | undefined>
  readonly terminate: (sandboxId: string) => Promise<void>
  readonly list: (tags: Record<string, string>) => Promise<ReadonlyArray<ModalSandboxRef>>
  readonly snapshot: (sandboxId: string) => Promise<string>
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const millisecondsPerMinute = 60 * 1000
const mebibytesPerGiB = 1024

export interface ModalTokens {
  readonly tokenId: string
  readonly tokenSecret: string
}

export const modalAdapter = (
  connectClient: (tokens: ModalTokens) => ModalClient
): SandboxAdapter => {
  const clientFor = (account: SandboxFieldValues) =>
    connectClient({
      tokenId: stringValue(account, "tokenId"),
      tokenSecret: stringValue(account, "tokenSecret")
    })
  return {
    definition: MODAL_DEFINITION,
    connect: (account) => makeModalProvider(clientFor(account)),
    verify: async (account) => {
      await clientFor(account).list(ownerFilter("codevisor-verify"))
      return {}
    }
  }
}

export const makeModalProvider = (
  client: ModalClient,
  now: () => number = Date.now
): SandboxProvider => ({
  definition: MODAL_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const timeoutMs = numberValue(options, "timeoutMinutes", 1440) * millisecondsPerMinute
    const sandboxId = await client.create({
      image: stringValue(options, "image"),
      setupCommands: defaultSetupCommands,
      cpu: numberValue(options, "cpu", 2),
      memoryMiB: numberValue(options, "memoryGiB", 4) * mebibytesPerGiB,
      timeoutMs,
      tags: tagsToRecord(spec.tags)
    })
    return {
      providerMachineId: sandboxId,
      platform: "linux",
      expiresAt: isoAfter(now(), timeoutMs)
    }
  },
  exec: (sandboxId, request) =>
    client.exec(sandboxId, request.script, {
      ...(request.stdin === undefined ? {} : { stdin: request.stdin }),
      timeoutMs: request.timeoutMs ?? defaultExecTimeoutMs
    }),
  status: async (sandboxId) => ({ state: stateFor(await client.isRunning(sandboxId)) }),
  destroy: (sandboxId) => client.terminate(sandboxId),
  list: async (owner) =>
    (await client.list(ownerFilter(owner))).flatMap((sandbox) =>
      listedMachine(sandbox.sandboxId, sandbox.tags)
    ),
  snapshot: async (sandboxId) => ({ snapshotId: await client.snapshot(sandboxId) })
})

const stateFor = (running: boolean | undefined): "running" | "stopped" | "gone" => {
  if (running === undefined) return "gone"
  return running ? "running" : "stopped"
}

const isoAfter = (startMs: number, durationMs: number): string =>
  new Date(startMs + durationMs).toISOString()
