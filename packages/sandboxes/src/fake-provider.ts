import { secretField, textField, type SandboxFieldValues } from "./fields.js"
import { pauseAfterField, type SandboxPausing } from "./pausing.js"
import type {
  CreateSpec,
  SandboxProvider,
  SandboxProviderId,
  ExecRequest,
  ExecResult,
  MachinePlatform,
  ProviderMachineState,
  ProvisionPlan,
  ProvisionProgress,
  ProvisionStage,
  SandboxProviderDefinition
} from "./provider.js"

export const fakeDefinition = (
  id: SandboxProviderId = "e2b",
  platform: MachinePlatform = "linux",
  pauses = false
): SandboxProviderDefinition => ({
  id,
  displayName: "Fake",
  sandboxNoun: "fake sandbox",
  platform,
  tested: true,
  accountFields: [secretField("apiKey", "API key")],
  profileFields: [
    textField("size", "Size", { default: "small" }),
    ...(pauses ? [pauseAfterField({ never: true })] : [])
  ]
})

export interface FakeMachine {
  readonly spec: CreateSpec
  readonly options: SandboxFieldValues
  state: ProviderMachineState
}

export type FakeExecHandler = (
  providerMachineId: string,
  request: ExecRequest
) => ExecResult | Promise<ExecResult>

export interface FakeProviderOptions {
  readonly id?: SandboxProviderId
  readonly platform?: MachinePlatform
  readonly onExec?: FakeExecHandler
  readonly resumable?: boolean
  readonly boots?: boolean
  readonly streams?: boolean
  readonly prepares?: boolean
  readonly pauses?: FakePauses
}

export type FakePauses = "in-place" | "snapshot"

export interface FakeSandboxProvider extends SandboxProvider {
  readonly machines: Map<string, FakeMachine>
  readonly execs: Array<{ readonly providerMachineId: string; readonly request: ExecRequest }>
  readonly keptAlive: Array<{ readonly providerMachineId: string; readonly untilMs: number }>
}

const succeeded: ExecResult = { exitCode: 0, stdout: "", stderr: "" }

export const makeFakeSandboxProvider = (options: FakeProviderOptions = {}): FakeSandboxProvider => {
  const machines = new Map<string, FakeMachine>()
  const execs: FakeSandboxProvider["execs"] = []
  const keptAlive: FakeSandboxProvider["keptAlive"] = []
  const onExec = options.onExec ?? (() => succeeded)
  const resume = (providerMachineId: string): Promise<void> => {
    const machine = machines.get(providerMachineId)
    if (machine !== undefined) machine.state = "running"
    return Promise.resolve()
  }
  const provisionStages: ReadonlyArray<ProvisionStage> =
    options.boots === true ? ["create", "boot"] : ["create"]
  return {
    ...(options.resumable === true ? { resume } : {}),
    ...(options.prepares === true ? preparesImage(provisionStages) : {}),
    ...(options.pauses === undefined
      ? {}
      : { pausing: fakePausing(options.pauses, machines, keptAlive) }),
    definition: fakeDefinition(options.id, options.platform, options.pauses !== undefined),
    provisionStages,
    streamsOutput: options.streams === true,
    machines,
    execs,
    keptAlive,
    create: (spec, machineOptions, progress) => {
      const providerMachineId = `fake-${machines.size + 1}`
      machines.set(providerMachineId, { spec, options: machineOptions, state: "running" })
      if (options.boots === true) {
        progress?.stage("boot")
        progress?.log(`Booting ${providerMachineId}`)
      }
      return Promise.resolve({
        providerMachineId,
        platform: options.platform ?? "linux",
        ...(options.prepares === true ? { preinstalled: true } : {})
      })
    },
    exec: async (providerMachineId, request) => {
      execs.push({ providerMachineId, request })
      const result = await onExec(providerMachineId, request)
      if (options.streams === true) request.onOutput?.("stdout", result.stdout)
      return result
    },
    status: (providerMachineId) =>
      Promise.resolve({ state: machines.get(providerMachineId)?.state ?? "gone" }),
    destroy: (providerMachineId) => {
      machines.delete(providerMachineId)
      return Promise.resolve()
    },
    list: (owner) =>
      Promise.resolve(
        [...machines]
          .filter(([, machine]) => machine.spec.tags.owner === owner)
          .map(([providerMachineId, machine]) => ({ providerMachineId, tags: machine.spec.tags }))
      )
  }
}

const fakePausing = (
  pauses: FakePauses,
  machines: Map<string, FakeMachine>,
  keptAlive: FakeSandboxProvider["keptAlive"]
): SandboxPausing => ({
  pause: (providerMachineId) => {
    const machine = machines.get(providerMachineId)
    if (machine === undefined) return Promise.reject(new Error(`No ${providerMachineId}`))
    if (pauses === "in-place") {
      machine.state = "stopped"
      return Promise.resolve({ providerMachineId })
    }
    machines.delete(providerMachineId)
    return Promise.resolve({ providerMachineId, snapshot: `snapshot-of-${providerMachineId}` })
  },
  wake: (paused, spec, options) => {
    const machine = machines.get(paused.providerMachineId)
    if (machine !== undefined) {
      machine.state = "running"
      return Promise.resolve({ providerMachineId: paused.providerMachineId })
    }
    const providerMachineId = `fake-${machines.size + 1}-from-${paused.snapshot ?? "nothing"}`
    machines.set(providerMachineId, { spec, options, state: "running" })
    return Promise.resolve({ providerMachineId })
  },
  ...(pauses === "in-place" ? { keepAlive: recordKeepAlive(keptAlive) } : {})
})

const recordKeepAlive =
  (keptAlive: FakeSandboxProvider["keptAlive"]) =>
  (providerMachineId: string, untilMs: number): Promise<string> => {
    keptAlive.push({ providerMachineId, untilMs })
    return Promise.resolve(new Date(untilMs).toISOString())
  }

const preparesImage = (provisionStages: ReadonlyArray<ProvisionStage>) => ({
  plan: (): Promise<ProvisionPlan> =>
    Promise.resolve({ stages: ["image", ...provisionStages], preinstalled: true }),
  prepare: (
    machineOptions: SandboxFieldValues,
    plan: ProvisionPlan,
    progress: ProvisionProgress
  ): Promise<SandboxFieldValues> => {
    if (plan.stages.includes("image")) {
      progress.stage("image")
      progress.log("Preparing the fake image")
    }
    return Promise.resolve(machineOptions)
  }
})
