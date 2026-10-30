import {
  choiceField,
  offeredChoiceField,
  optionalString,
  secretField,
  stringValue,
  textField,
  type SandboxField,
  type SandboxFieldChoice
} from "./fields.js"
import { pauseAfterField, type SandboxPausing } from "./pausing.js"
import {
  SandboxChoiceNeeded,
  type ExecResult,
  type ProviderMachineState,
  type ProviderMachineStatus,
  type SandboxAdapter,
  type SandboxProvider,
  type SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, ownerFilter, tagsToRecord } from "./tags.js"

export const VERCEL_DEFAULT_IMAGE = "vercel/sandbox/universal"
export const VERCEL_PROJECT_NAME = "codevisor-sandboxes"

const defaultVcpus = "2"
const memoryGBPerVcpu = 2
const vcpuChoices: ReadonlyArray<SandboxFieldChoice> = [1, 2, 4, 8, 16, 32].map((vcpus) => ({
  value: String(vcpus),
  label: `${vcpus} ${vcpus === 1 ? "vCPU" : "vCPUs"} · ${vcpus * memoryGBPerVcpu} GB`
}))
const teamField = offeredChoiceField("teamId", "Team", {
  help: "This token can reach more than one team. Sandboxes go in this one."
})

export const VERCEL_DEFINITION: SandboxProviderDefinition = {
  id: "vercel",
  displayName: "Vercel Sandbox",
  sandboxNoun: "Vercel sandbox",
  platform: "linux",
  tested: false,
  accountFields: [
    secretField("token", "Access token", {
      required: true,
      help: `Create one in Vercel under Account Settings › Tokens. Sandboxes go in a ${VERCEL_PROJECT_NAME} project on its team.`
    }),
    teamField
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
    pauseAfterField({ never: true })
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
  readonly stop: (name: string) => Promise<void>
  readonly extend: (name: string, durationMs: number) => Promise<void>
  readonly remove: (name: string) => Promise<void>
  readonly list: (tags: Record<string, string>) => Promise<ReadonlyArray<VercelSandboxInfo>>
}

export interface VercelCredentials {
  readonly token: string
  readonly teamId: string
  readonly projectId: string
}

export interface VercelUser {
  readonly email?: string
  readonly defaultTeamId?: string
}

export interface VercelTeam {
  readonly id: string
  readonly name: string
}

export interface VercelAccount {
  readonly user: () => Promise<VercelUser>
  readonly teams: () => Promise<ReadonlyArray<VercelTeam>>
  readonly project: (teamId: string, name: string) => Promise<string>
}

const defaultExecTimeoutMs = 10 * 60 * 1000
const sessionWindowMs = 45 * 60 * 1000

export const vercelAdapter = (
  connectClient: (credentials: VercelCredentials) => VercelClient,
  connectAccount: (token: string) => VercelAccount
): SandboxAdapter => ({
  definition: VERCEL_DEFINITION,
  connect: (account) =>
    makeVercelProvider(
      connectClient({
        token: stringValue(account, "token"),
        teamId: stringValue(account, "teamId"),
        projectId: stringValue(account, "projectId")
      })
    ),
  verify: async (account) => {
    const token = stringValue(account, "token")
    const vercel = connectAccount(token)
    const [user, teams] = await Promise.all([vercel.user(), vercel.teams()])
    const teamId = teamFor(teams, user.defaultTeamId, optionalString(account, "teamId"))
    const projectId = await vercel.project(teamId, VERCEL_PROJECT_NAME)
    await connectClient({ token, teamId, projectId }).list(ownerFilter("codevisor-verify"))
    return { ...identityFor(user.email), resolved: { teamId, projectId } }
  }
})

export const makeVercelProvider = (client: VercelClient): SandboxProvider => ({
  definition: VERCEL_DEFINITION,
  provisionStages: ["create"],
  streamsOutput: false,
  create: async (spec, options) => {
    const sandbox = await client.create({
      image: stringValue(options, "image"),
      vcpus: Number(optionalString(options, "vcpus") ?? defaultVcpus),
      timeoutMs: sessionWindowMs,
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
    ),
  pausing: vercelPausing(client)
})

const vercelPausing = (client: VercelClient): SandboxPausing => ({
  pause: async (name) => {
    await client.stop(name)
    return { providerMachineId: name }
  },
  wake: async (paused) => {
    await client.resume(paused.providerMachineId)
    return {
      providerMachineId: paused.providerMachineId,
      ...expiry(await client.info(paused.providerMachineId))
    }
  },
  keepAlive: async (name, untilMs) => {
    const expiresAt = (await client.info(name))?.expiresAt?.getTime()
    if (expiresAt === undefined || expiresAt >= untilMs) return isoOrUndefined(expiresAt)

    await client.extend(name, untilMs - expiresAt)
    return new Date(untilMs).toISOString()
  }
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

const expiry = (sandbox: VercelSandboxInfo | undefined): { readonly expiresAt?: string } =>
  sandbox?.expiresAt === undefined ? {} : { expiresAt: sandbox.expiresAt.toISOString() }

const isoOrUndefined = (ms: number | undefined): string | undefined =>
  ms === undefined ? undefined : new Date(ms).toISOString()

const teamFor = (
  teams: ReadonlyArray<VercelTeam>,
  defaultTeamId: string | undefined,
  chosen: string | undefined
): string => {
  if (chosen !== undefined && teams.some((team) => team.id === chosen)) return chosen
  const [only, ...others] = teams
  if (only === undefined) throw new Error("This token can't reach any Vercel team")
  if (others.length > 0) {
    throw new SandboxChoiceNeeded(
      teamChoice(teams, defaultTeamId),
      "This token can reach more than one Vercel team. Choose the team for your sandboxes."
    )
  }
  return only.id
}

const teamChoice = (
  teams: ReadonlyArray<VercelTeam>,
  defaultTeamId: string | undefined
): SandboxField => ({
  ...teamField,
  required: true,
  choices: teams.map((team) => ({ value: team.id, label: team.name })),
  ...(defaultTeamId !== undefined && teams.some((team) => team.id === defaultTeamId)
    ? { default: defaultTeamId }
    : {})
})

const identityFor = (email: string | undefined): { readonly identity?: string } =>
  email === undefined ? {} : { identity: email }
