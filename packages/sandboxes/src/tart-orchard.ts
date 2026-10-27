import { setTimeout as delay } from "node:timers/promises"

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
import {
  SandboxProviderError,
  type ExecRequest,
  type ExecResult,
  type ListedMachine,
  type OutputStream,
  type ProviderMachineState,
  type ProvisionProgress,
  type SandboxAccountIdentity,
  type SandboxAdapter,
  type SandboxProvider,
  type SandboxProviderDefinition,
  type SandboxTags
} from "./provider.js"
import { silentProgress } from "./tart-vm.js"
import { DEFAULT_TART_BASE_IMAGE, vmName } from "./tart.js"

export const TART_ORCHARD_DEFINITION: SandboxProviderDefinition = {
  id: "tart-orchard",
  displayName: "Tart Orchard",
  sandboxNoun: "Orchard VM",
  platform: "darwin",
  tested: false,
  accountFields: [
    urlField("controllerUrl", "Controller URL", {
      required: true,
      placeholder: "https://orchard.example.com:6120",
      help: "The Orchard controller's address. It listens on port 6120 unless configured otherwise."
    }),
    textField("serviceAccountName", "Service account name", {
      required: true,
      help: "A service account with the compute:read and compute:write roles."
    }),
    secretField("serviceAccountToken", "Service account token", { required: true }),
    textField("certificateFingerprint", "Certificate fingerprint", {
      placeholder: "AB CD EF …",
      help: "Only for a controller using its self-signed certificate: the SHA-256 fingerprint that orchard context create prints."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      required: true,
      default: DEFAULT_TART_BASE_IMAGE,
      help: "A macOS Tart image that the Orchard workers can pull."
    }),
    numberField("cpu", "CPUs", { default: 4, min: 1, max: 32 }),
    numberField("memoryGiB", "Memory (GiB)", { default: 8, min: 2, max: 128 }),
    numberField("diskSizeGB", "Disk size (GB)", {
      min: 20,
      max: 4096,
      help: "Grows the image's disk to this size. Leave empty to keep the image's size."
    }),
    textField("username", "Username", {
      default: "admin",
      help: "The image's administrator. Orchard runs commands as this user over SSH, so it needs passwordless sudo."
    }),
    textField("password", "Password", { default: "admin" })
  ]
}

export interface TartOrchardCredentials {
  readonly controllerUrl: string
  readonly serviceAccountName: string
  readonly serviceAccountToken: string
  readonly certificateFingerprint?: string
}

export interface OrchardVmSpec {
  readonly name: string
  readonly os: "darwin"
  readonly image: string
  readonly cpu: number
  readonly memory: number
  readonly diskSize?: number
  readonly headless: boolean
  readonly username: string
  readonly password: string
}

export interface OrchardVm {
  readonly name: string
  readonly status: string
  readonly statusMessage?: string
  readonly worker?: string
  readonly resources: Readonly<Record<string, number>>
}

export interface OrchardWorker {
  readonly name: string
  readonly schedulingPaused: boolean
  readonly resources: Readonly<Record<string, number>>
}

export interface OrchardControllerInfo {
  readonly version?: string
}

export interface OrchardExecRequest {
  readonly command: string
  readonly stdin?: string
  readonly waitSeconds: number
  readonly timeoutMs: number
  readonly onOutput?: (stream: OutputStream, text: string) => void
}

export interface OrchardExecOutput {
  readonly stdout: string
  readonly stderr: string
}

export type OrchardExecOutcome =
  | (OrchardExecOutput & { readonly kind: "exited"; readonly exitCode: number })
  | (OrchardExecOutput & { readonly kind: "failed"; readonly message: string })
  | (OrchardExecOutput & { readonly kind: "timedOut" })

export interface OrchardPortForward {
  readonly host: string
  readonly port: number
  readonly close: () => Promise<void>
}

export interface TartOrchardClient {
  readonly controllerInfo: () => Promise<OrchardControllerInfo>
  readonly createVm: (spec: OrchardVmSpec) => Promise<void>
  readonly getVm: (name: string) => Promise<OrchardVm | undefined>
  readonly listVms: () => Promise<ReadonlyArray<OrchardVm>>
  readonly deleteVm: (name: string) => Promise<void>
  readonly listWorkers: () => Promise<ReadonlyArray<OrchardWorker>>
  readonly exec: (name: string, request: OrchardExecRequest) => Promise<OrchardExecOutcome>
  readonly forwardPort: (name: string, port: number) => Promise<OrchardPortForward>
}

export interface TartOrchardClock {
  readonly now: () => number
  readonly sleep: (ms: number) => Promise<void>
}

export const TART_VMS_RESOURCE = "org.cirruslabs.tart-vms"

export const tartOrchardAdapter = (
  connectClient: (credentials: TartOrchardCredentials) => TartOrchardClient,
  clock: TartOrchardClock = systemClock
): SandboxAdapter => {
  const clientFor = (account: SandboxFieldValues) => connectClient(credentialsFrom(account))
  return {
    definition: TART_ORCHARD_DEFINITION,
    connect: (account) => makeTartOrchardProvider(clientFor(account), clock),
    verify: async (account) => identityFrom(await clientFor(account).controllerInfo())
  }
}

export const makeTartOrchardProvider = (
  client: TartOrchardClient,
  clock: TartOrchardClock = systemClock
): SandboxProvider => {
  const forwards = vncForwards(client)
  return {
    definition: TART_ORCHARD_DEFINITION,
    provisionStages: ["create", "boot"],
    streamsOutput: true,
    availability: async () => {
      const [workers, vms] = await Promise.all([client.listWorkers(), client.listVms()])
      return capacityShortfall(workers, vms)
    },
    create: async (spec, values, progress = silentProgress) => {
      const vm = vmSpec(vmName(spec), values)
      await createAndBoot(client, clock, vm, progress)
      return { providerMachineId: vm.name, platform: "darwin" }
    },
    exec: async (name, request) => execResult(await client.exec(name, execRequest(request))),
    status: async (name) => ({ state: stateFor(await client.getVm(name)) }),
    destroy: async (name) => {
      await forwards.close(name)
      await client.deleteVm(name)
    },
    list: async (owner) => (await client.listVms()).flatMap((vm) => ownedMachine(vm.name, owner)),
    gui: async (name) => {
      const forward = await forwards.open(name)
      return { vncUrl: `vnc://${forward.host}:${forward.port}` }
    }
  }
}

const systemClock: TartOrchardClock = { now: Date.now, sleep: delay }

const providerId = TART_ORCHARD_DEFINITION.id
const vmPrefix = "codevisor_"
const mebibytesPerGiB = 1024
const millisecondsPerSecond = 1000
const defaultExecTimeoutMs = 10 * 60 * 1000
const execWaitSeconds = 60
const sshWaitSeconds = 180
const sshProbeTimeoutMs = (sshWaitSeconds + 30) * millisecondsPerSecond
const vmStartTimeoutMs = 60 * 60 * 1000
const statusPollMs = 2000
const timedOutExitCode = 124
const vncPort = 5900
const minimumVersion = "0.51.0"

const credentialsFrom = (account: SandboxFieldValues): TartOrchardCredentials => {
  const certificateFingerprint = optionalString(account, "certificateFingerprint")
  return {
    controllerUrl: stringValue(account, "controllerUrl"),
    serviceAccountName: stringValue(account, "serviceAccountName"),
    serviceAccountToken: stringValue(account, "serviceAccountToken"),
    ...(certificateFingerprint === undefined ? {} : { certificateFingerprint })
  }
}

const identityFrom = (info: OrchardControllerInfo): SandboxAccountIdentity => {
  const rank = info.version === undefined ? undefined : versionRank(info.version)
  if (rank === undefined) return {}
  if (rank < minimumRank) throw tooOld(info)

  return { identity: `Orchard ${info.version}` }
}

const versionRank = (version: string): number | undefined => {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(version)
  if (match === null) return undefined
  return rankOf(Number(match[1]), Number(match[2]), Number(match[3]))
}

const rankOf = (major: number, minor: number, patch: number): number =>
  (major * 1000 + minor) * 1000 + patch

const minimumRank = rankOf(0, 51, 0)

const tooOld = (info: OrchardControllerInfo): SandboxProviderError =>
  new SandboxProviderError(
    providerId,
    `This controller runs Orchard ${String(info.version)}; Codevisor needs Orchard ${minimumVersion} or later`
  )

const vmSpec = (name: string, values: SandboxFieldValues): OrchardVmSpec => {
  const diskSize = values.diskSizeGB
  return {
    name,
    os: "darwin",
    image: stringValue(values, "image"),
    cpu: numberValue(values, "cpu", 4),
    memory: numberValue(values, "memoryGiB", 8) * mebibytesPerGiB,
    ...(typeof diskSize === "number" ? { diskSize } : {}),
    headless: true,
    username: stringValue(values, "username"),
    password: stringValue(values, "password")
  }
}

const createAndBoot = async (
  client: TartOrchardClient,
  clock: TartOrchardClock,
  vm: OrchardVmSpec,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log(`Creating Orchard VM ${vm.name} from ${vm.image}`)
  await client.createVm(vm)
  try {
    await waitUntilRunning(client, clock, vm.name, progress)
    progress.stage("boot")
    await waitForSsh(client, vm.name, progress)
  } catch (cause) {
    await client.deleteVm(vm.name)
    throw cause
  }
}

const waitUntilRunning = async (
  client: TartOrchardClient,
  clock: TartOrchardClock,
  name: string,
  progress: ProvisionProgress
): Promise<void> => {
  const deadline = clock.now() + vmStartTimeoutMs
  const report = pendingReporter(progress)
  for (;;) {
    const vm = await client.getVm(name)
    if (vm?.status === "running") return
    assertStarting(name, vm)
    report(vm)
    if (clock.now() >= deadline) throw startTimeout(name)
    await clock.sleep(statusPollMs)
  }
}

function assertStarting(name: string, vm: OrchardVm | undefined): asserts vm is OrchardVm {
  if (vm === undefined) throw new SandboxProviderError(providerId, `Orchard VM ${name} disappeared`)
  if (vm.status === "failed") throw failedVm(vm)
}

const failedVm = (vm: OrchardVm): SandboxProviderError =>
  new SandboxProviderError(
    providerId,
    `Orchard VM ${vm.name} failed: ${vm.statusMessage ?? "no reason given"}`
  )

const startTimeout = (name: string): SandboxProviderError =>
  new SandboxProviderError(
    providerId,
    `Orchard VM ${name} did not start within ${vmStartTimeoutMs / 60_000} minutes`
  )

const pendingReporter = (progress: ProvisionProgress) => {
  let reported: string | undefined
  return (vm: OrchardVm): void => {
    const line = pendingLine(vm)
    if (line === reported) return

    reported = line
    progress.log(line)
  }
}

const pendingLine = (vm: OrchardVm): string => {
  if (vm.statusMessage !== undefined) return vm.statusMessage
  if (vm.worker === undefined) return "Waiting for an Orchard worker with a free macOS VM slot"
  return `Starting on Orchard worker ${vm.worker}`
}

const waitForSsh = async (
  client: TartOrchardClient,
  name: string,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log("Waiting for SSH")
  const probe = { command: "true", waitSeconds: sshWaitSeconds, timeoutMs: sshProbeTimeoutMs }
  const result = execResult(await client.exec(name, probe))
  if (result.exitCode !== 0) throw sshFailure(name, result)

  progress.log("SSH is ready")
}

const sshFailure = (name: string, result: ExecResult): SandboxProviderError =>
  new SandboxProviderError(
    providerId,
    `SSH into Orchard VM ${name} failed (exit ${result.exitCode}): ${result.stderr.trim()}`
  )

const execRequest = (request: ExecRequest): OrchardExecRequest => ({
  command: `sh -c ${shellQuote(request.script)}`,
  waitSeconds: execWaitSeconds,
  timeoutMs: request.timeoutMs ?? defaultExecTimeoutMs,
  ...(request.stdin === undefined ? {} : { stdin: request.stdin }),
  ...(request.onOutput === undefined ? {} : { onOutput: request.onOutput })
})

const execResult = (outcome: OrchardExecOutcome): ExecResult => {
  if (outcome.kind === "failed") {
    throw new SandboxProviderError(
      providerId,
      `Orchard couldn't run the command: ${outcome.message}`
    )
  }
  if (outcome.kind === "timedOut") {
    return { exitCode: timedOutExitCode, stdout: outcome.stdout, stderr: timedOutStderr(outcome) }
  }
  return { exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr }
}

const timedOutStderr = (output: OrchardExecOutput): string =>
  `${output.stderr}The command timed out and Codevisor disconnected from it\n`

const machineStates: Readonly<Record<string, ProviderMachineState>> = {
  pending: "starting",
  running: "running"
}

const stateFor = (vm: OrchardVm | undefined): ProviderMachineState => {
  if (vm === undefined) return "gone"
  return machineStates[vm.status] ?? "stopped"
}

const capacityShortfall = (
  workers: ReadonlyArray<OrchardWorker>,
  vms: ReadonlyArray<OrchardVm>
): string | undefined => {
  const accepting = workers.filter((worker) => !worker.schedulingPaused)
  if (accepting.length === 0) return "No Orchard worker is accepting new VMs"
  if (freeMacOSSlots(accepting, vms) > 0) return undefined

  return "Every macOS VM slot on the Orchard workers is taken"
}

const freeMacOSSlots = (
  workers: ReadonlyArray<OrchardWorker>,
  vms: ReadonlyArray<OrchardVm>
): number => {
  const free = workers.map((worker) =>
    Math.max(0, macOSSlots(worker.resources) - slotsOn(vms, worker.name))
  )
  return sum(free) - sum(vms.filter(unscheduled).map((vm) => macOSSlots(vm.resources)))
}

const slotsOn = (vms: ReadonlyArray<OrchardVm>, worker: string): number =>
  sum(vms.filter((vm) => vm.worker === worker).map((vm) => macOSSlots(vm.resources)))

const unscheduled = (vm: OrchardVm): boolean => vm.worker === undefined

const macOSSlots = (resources: Readonly<Record<string, number>>): number =>
  resources[TART_VMS_RESOURCE] ?? 0

const sum = (values: ReadonlyArray<number>): number =>
  values.reduce((total, value) => total + value, 0)

const ownedMachine = (name: string, owner: string): ReadonlyArray<ListedMachine> => {
  const tags = tagsFromVmName(name)
  if (tags?.owner !== owner) return []

  return [{ providerMachineId: name, tags }]
}

const tagsFromVmName = (name: string): SandboxTags | undefined => {
  if (!name.startsWith(vmPrefix)) return undefined
  const [owner, machine] = name.slice(vmPrefix.length).split("_")
  if (owner === undefined || machine === undefined) return undefined

  return { owner, machine }
}

const vncForwards = (client: TartOrchardClient) => {
  const opened = new Map<string, Promise<OrchardPortForward>>()
  return {
    open: (name: string): Promise<OrchardPortForward> => {
      const existing = opened.get(name)
      if (existing !== undefined) return existing

      const forward = client.forwardPort(name, vncPort)
      opened.set(name, forward)
      void forward.catch(() => opened.delete(name))
      return forward
    },
    close: async (name: string): Promise<void> => {
      const forward = opened.get(name)
      opened.delete(name)
      if (forward !== undefined) await (await forward).close()
    }
  }
}
