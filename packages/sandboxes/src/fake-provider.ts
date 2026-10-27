import { secretField, textField, type SandboxFieldValues } from "./fields.js"
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
  platform: MachinePlatform = "linux"
): SandboxProviderDefinition => ({
  id,
  displayName: "Fake",
  sandboxNoun: "fake sandbox",
  platform,
  tested: true,
  accountFields: [secretField("apiKey", "API key")],
  profileFields: [textField("size", "Size", { default: "small" })]
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
}

export interface FakeSandboxProvider extends SandboxProvider {
  readonly machines: Map<string, FakeMachine>
  readonly execs: Array<{ readonly providerMachineId: string; readonly request: ExecRequest }>
}

const succeeded: ExecResult = { exitCode: 0, stdout: "", stderr: "" }

export const makeFakeSandboxProvider = (options: FakeProviderOptions = {}): FakeSandboxProvider => {
  const machines = new Map<string, FakeMachine>()
  const execs: FakeSandboxProvider["execs"] = []
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
    definition: fakeDefinition(options.id, options.platform),
    provisionStages,
    streamsOutput: options.streams === true,
    machines,
    execs,
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
