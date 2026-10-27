import { Effect, Schema } from "effect"

import type { SandboxProvider, ExecResult } from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

export const E2bOptions = Schema.Struct({
  template: Schema.String.pipe(Schema.withDecodingDefaultKey(Effect.succeed("base"))),
  timeoutMinutes: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(60)))
})
export type E2bOptions = typeof E2bOptions.Type

export interface E2bSandboxInfo {
  readonly sandboxId: string
  readonly endAt?: Date
  readonly metadata: Readonly<Record<string, string>>
}

export interface E2bClient {
  readonly create: (
    template: string,
    options: { readonly timeoutMs: number; readonly metadata: Record<string, string> }
  ) => Promise<E2bSandboxInfo>
  readonly runAsRoot: (
    sandboxId: string,
    script: string,
    options: { readonly stdin?: string; readonly timeoutMs: number }
  ) => Promise<ExecResult>
  readonly info: (sandboxId: string) => Promise<E2bSandboxInfo | undefined>
  readonly kill: (sandboxId: string) => Promise<void>
  readonly list: (metadata: Record<string, string>) => Promise<ReadonlyArray<E2bSandboxInfo>>
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const millisecondsPerMinute = 60 * 1000

export const makeE2bProvider = (client: E2bClient): SandboxProvider<E2bOptions> => ({
  id: "e2b",
  displayName: "E2B",
  options: E2bOptions,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const sandbox = await client.create(options.template, {
      timeoutMs: options.timeoutMinutes * millisecondsPerMinute,
      metadata: tagsToRecord(spec.tags)
    })
    return { providerMachineId: sandbox.sandboxId, platform: "linux", ...expiry(sandbox) }
  },
  exec: (sandboxId, request) =>
    client.runAsRoot(sandboxId, request.script, {
      ...(request.stdin === undefined ? {} : { stdin: request.stdin }),
      timeoutMs: request.timeoutMs ?? defaultExecTimeoutMs
    }),
  status: async (sandboxId) => {
    const sandbox = await client.info(sandboxId)
    if (sandbox === undefined) return { state: "gone" }

    return { state: "running", ...expiry(sandbox) }
  },
  destroy: (sandboxId) => client.kill(sandboxId),
  list: async (owner) =>
    (await client.list(ownerFilter(owner))).flatMap((sandbox) =>
      listedMachine(sandbox.sandboxId, sandbox.metadata)
    )
})

const expiry = (sandbox: E2bSandboxInfo): { readonly expiresAt?: string } =>
  sandbox.endAt === undefined ? {} : { expiresAt: sandbox.endAt.toISOString() }
