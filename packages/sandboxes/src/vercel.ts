import {
  choiceField,
  numberField,
  numberValue,
  optionalString,
  secretField,
  stringValue,
  textField,
  type SandboxFieldChoice,
  type SandboxFieldValues
} from "./fields.js"
import type {
  ExecResult,
  ProviderMachineState,
  ProviderMachineStatus,
  SandboxAccountIdentity,
  SandboxAdapter,
  SandboxProvider,
  SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

export const VERCEL_DEFAULT_IMAGE = "vercel/sandbox/universal"

const defaultVcpus = "2"
const memoryGBPerVcpu = 2
const vcpuChoices: ReadonlyArray<SandboxFieldChoice> = [1, 2, 4, 8, 16, 32].map((vcpus) => ({
  value: String(vcpus),
  label: `${vcpus} ${vcpus === 1 ? "vCPU" : "vCPUs"} · ${vcpus * memoryGBPerVcpu} GB`
}))
const defaultSessionMinutes = 45

export const VERCEL_DEFINITION: SandboxProviderDefinition = {
  id: "vercel",
  displayName: "Vercel Sandbox",
  sandboxNoun: "Vercel sandbox",
  platform: "linux",
  tested: false,
  accountFields: [
    secretField("token", "Access token", {
      required: true,
      help: "Create one in Vercel under Account Settings › Tokens, scoped to the team below."
    }),
    textField("teamId", "Team ID", {
      required: true,
      placeholder: "team_…",
      help: "Shown in your team's Settings › General."
    }),
    textField("projectId", "Project ID", {
      required: true,
      placeholder: "prj_…",
      help: "Sandboxes belong to this project. Shown in its Settings › General."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      default: VERCEL_DEFAULT_IMAGE,
      help: "A Vercel managed image or one of your VCR images. It needs curl, git and sudo, which the universal image has."
    }),
    choiceField("vcpus", "vCPUs", vcpuChoices, {
      default: defaultVcpus,
      help: "Hobby allows up to 4, Pro 8 and Enterprise 32."
    }),
    numberField("timeoutMinutes", "Session length (minutes)", {
      default: defaultSessionMinutes,
      min: 1,
      max: 1440,
      help: "Up to 45 on Hobby and 1440 on Pro. When a session ends, the sandbox keeps its disk and Codevisor resumes it."
    })
  ]
}

export interface VercelSandboxInfo {
  readonly name: string
  readonly status: string
  readonly expiresAt?: Date
  readonly tags: Readonly<Record<string, string>>
}

export interface VercelCreateRequest {
  readonly image: string
  readonly vcpus: number
  readonly timeoutMs: number
  readonly tags: Record<string, string>
}

export interface VercelClient {
  readonly create: (request: VercelCreateRequest) => Promise<VercelSandboxInfo>
  readonly runAsRoot: (
    name: string,
    script: string,
    options: { readonly stdin?: string; readonly timeoutMs: number }
  ) => Promise<ExecResult>
  readonly info: (name: string) => Promise<VercelSandboxInfo | undefined>
  readonly resume: (name: string) => Promise<void>
  readonly remove: (name: string) => Promise<void>
  readonly list: (tags: Record<string, string>) => Promise<ReadonlyArray<VercelSandboxInfo>>
  readonly email: () => Promise<string | undefined>
}

export interface VercelCredentials {
  readonly token: string
  readonly teamId: string
  readonly projectId: string
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const millisecondsPerMinute = 60 * 1000

export const vercelAdapter = (
  connectClient: (credentials: VercelCredentials) => VercelClient
): SandboxAdapter => {
  const clientFor = (account: SandboxFieldValues) =>
    connectClient({
      token: stringValue(account, "token"),
      teamId: stringValue(account, "teamId"),
      projectId: stringValue(account, "projectId")
    })
  return {
    definition: VERCEL_DEFINITION,
    connect: (account) => makeVercelProvider(clientFor(account)),
    verify: async (account) => {
      const client = clientFor(account)
      await client.list(ownerFilter("codevisor-verify"))
      return identityFor(await client.email())
    }
  }
}

export const makeVercelProvider = (client: VercelClient): SandboxProvider => ({
  definition: VERCEL_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const sandbox = await client.create({
      image: stringValue(options, "image"),
      vcpus: Number(optionalString(options, "vcpus") ?? defaultVcpus),
      timeoutMs:
        numberValue(options, "timeoutMinutes", defaultSessionMinutes) * millisecondsPerMinute,
      tags: tagsToRecord(spec.tags)
    })
    return { providerMachineId: sandbox.name, platform: "linux", ...expiry(sandbox) }
  },
  exec: (name, request) =>
    client.runAsRoot(name, request.script, {
      ...(request.stdin === undefined ? {} : { stdin: request.stdin }),
      timeoutMs: request.timeoutMs ?? defaultExecTimeoutMs
    }),
  status: async (name) => statusFor(await client.info(name)),
  resume: (name) => client.resume(name),
  destroy: (name) => client.remove(name),
  list: async (owner) =>
    (await client.list(ownerFilter(owner))).flatMap((sandbox) =>
      listedMachine(sandbox.name, sandbox.tags)
    )
})

const machineStates: Readonly<Record<string, ProviderMachineState>> = {
  pending: "starting",
  running: "running",
  stopping: "starting",
  snapshotting: "starting",
  stopped: "stopped",
  failed: "gone",
  aborted: "gone"
}

const statusFor = (sandbox: VercelSandboxInfo | undefined): ProviderMachineStatus => {
  if (sandbox === undefined) return { state: "gone" }

  return { state: machineStates[sandbox.status] ?? "starting", ...expiry(sandbox) }
}

const expiry = (sandbox: VercelSandboxInfo): { readonly expiresAt?: string } =>
  sandbox.expiresAt === undefined ? {} : { expiresAt: sandbox.expiresAt.toISOString() }

const identityFor = (email: string | undefined): SandboxAccountIdentity =>
  email === undefined ? {} : { identity: email }
