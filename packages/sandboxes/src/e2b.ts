import { numberField, numberValue, secretField, stringValue, textField } from "./fields.js"
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
    numberField("timeoutMinutes", "Lifetime (minutes)", { default: 60, min: 5, max: 1440 })
  ]
}

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

export const e2bAdapter = (connectClient: (apiKey: string) => E2bClient): SandboxAdapter => ({
  definition: E2B_DEFINITION,
  connect: (account) => makeE2bProvider(connectClient(stringValue(account, "apiKey"))),
  verify: async (account) => {
    await connectClient(stringValue(account, "apiKey")).list(ownerFilter("codevisor-verify"))
    return {}
  }
})

export const makeE2bProvider = (client: E2bClient): SandboxProvider => ({
  definition: E2B_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const sandbox = await client.create(stringValue(options, "template"), {
      timeoutMs: numberValue(options, "timeoutMinutes", 60) * millisecondsPerMinute,
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
