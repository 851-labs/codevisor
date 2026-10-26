import { Effect, Schema } from "effect"

import type { EphemeralProvider, ExecResult } from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

const defaultSetupCommands = [
  "RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git sudo procps && rm -rf /var/lib/apt/lists/*"
]

export const MODAL_APP_NAME = "codevisor-ephemeral"

export const ModalOptions = Schema.Struct({
  image: Schema.String.pipe(Schema.withDecodingDefaultKey(Effect.succeed("debian:bookworm-slim"))),
  setupCommands: Schema.Array(Schema.String).pipe(
    Schema.withDecodingDefaultKey(Effect.succeed(defaultSetupCommands))
  ),
  cpu: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(2))),
  memoryMiB: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(4096))),
  timeoutMinutes: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(24 * 60)))
})
export type ModalOptions = typeof ModalOptions.Type

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

export const makeModalProvider = (
  client: ModalClient,
  now: () => number = Date.now
): EphemeralProvider<ModalOptions> => ({
  id: "modal",
  displayName: "Modal",
  options: ModalOptions,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const timeoutMs = options.timeoutMinutes * millisecondsPerMinute
    const sandboxId = await client.create({ ...options, timeoutMs, tags: tagsToRecord(spec.tags) })
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
