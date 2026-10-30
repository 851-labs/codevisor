import { secretField, stringValue, textField } from "./fields.js"
import { pauseAfterField, type SandboxPausing } from "./pausing.js"
import type {
  ExecResult,
  SandboxAdapter,
  SandboxProvider,
  SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

export const E2B_DEFINITION: SandboxProviderDefinition = {
  id: "e2b",
  displayName: "E2B",
  sandboxNoun: "E2B sandbox",
  platform: "linux",
  tested: true,
  accountFields: [
    secretField("apiKey", "API key", {
      required: true,
      placeholder: "e2b_…",
      help: "Create one in the E2B dashboard under API Keys."
    })
  ],
  profileFields: [
    textField("template", "Template", {
      default: "base",
      help: "An E2B template name or ID. Each template is its own profile."
    }),
    pauseAfterField({ never: true })
  ]
}

export interface E2bSandboxInfo {
  readonly sandboxId: string
  readonly state: "running" | "paused"
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
  readonly pause: (sandboxId: string) => Promise<void>
  readonly resume: (sandboxId: string, timeoutMs: number) => Promise<E2bSandboxInfo>
  readonly setTimeout: (sandboxId: string, timeoutMs: number) => Promise<void>
  readonly kill: (sandboxId: string) => Promise<void>
  readonly list: (metadata: Record<string, string>) => Promise<ReadonlyArray<E2bSandboxInfo>>
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const vendorWindowMs = 60 * 60 * 1000

export const e2bAdapter = (connectClient: (apiKey: string) => E2bClient): SandboxAdapter => ({
  definition: E2B_DEFINITION,
  connect: (account) => makeE2bProvider(connectClient(stringValue(account, "apiKey"))),
  verify: async (account) => {
    await connectClient(stringValue(account, "apiKey")).list(ownerFilter("codevisor-verify"))
    return {}
  }
})

export const makeE2bProvider = (
  client: E2bClient,
  now: () => number = Date.now
): SandboxProvider => ({
  definition: E2B_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const sandbox = await client.create(stringValue(options, "template"), {
      timeoutMs: vendorWindowMs,
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

    return { state: sandbox.state === "paused" ? "stopped" : "running", ...expiry(sandbox) }
  },
  destroy: (sandboxId) => client.kill(sandboxId),
  list: async (owner) =>
    (await client.list(ownerFilter(owner))).flatMap((sandbox) =>
      listedMachine(sandbox.sandboxId, sandbox.metadata)
    ),
  pausing: e2bPausing(client, now)
})

const e2bPausing = (client: E2bClient, now: () => number): SandboxPausing => ({
  pause: async (sandboxId) => {
    await client.pause(sandboxId)
    return { providerMachineId: sandboxId }
  },
  wake: async (paused) => {
    const sandbox = await client.resume(paused.providerMachineId, vendorWindowMs)
    return { providerMachineId: sandbox.sandboxId, ...expiry(sandbox) }
  },
  keepAlive: async (sandboxId, untilMs) => {
    const timeoutMs = Math.min(untilMs - now(), vendorWindowMs)
    await client.setTimeout(sandboxId, timeoutMs)
    return new Date(now() + timeoutMs).toISOString()
  }
})

const expiry = (sandbox: E2bSandboxInfo): { readonly expiresAt?: string } =>
  sandbox.endAt === undefined ? {} : { expiresAt: sandbox.endAt.toISOString() }
