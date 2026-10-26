import { Effect, Schema } from "effect"

import type {
  CreateSpec,
  EphemeralProvider,
  EphemeralProviderId,
  ExecRequest,
  ExecResult,
  MachinePlatform,
  ProviderMachineState
} from "./provider.js"

export const FakeOptions = Schema.Struct({
  size: Schema.String.pipe(Schema.withDecodingDefaultKey(Effect.succeed("small")))
})
export type FakeOptions = typeof FakeOptions.Type

export interface FakeMachine {
  readonly spec: CreateSpec
  readonly options: FakeOptions
  state: ProviderMachineState
}

export type FakeExecHandler = (
  providerMachineId: string,
  request: ExecRequest
) => ExecResult | Promise<ExecResult>

export interface FakeProviderOptions {
  readonly id?: EphemeralProviderId
  readonly platform?: MachinePlatform
  readonly onExec?: FakeExecHandler
  readonly resumable?: boolean
  readonly boots?: boolean
  readonly streams?: boolean
}

export interface FakeEphemeralProvider extends EphemeralProvider<FakeOptions> {
  readonly machines: Map<string, FakeMachine>
  readonly execs: Array<{ readonly providerMachineId: string; readonly request: ExecRequest }>
}

const succeeded: ExecResult = { exitCode: 0, stdout: "", stderr: "" }

export const makeFakeEphemeralProvider = (
  options: FakeProviderOptions = {}
): FakeEphemeralProvider => {
  const machines = new Map<string, FakeMachine>()
  const execs: FakeEphemeralProvider["execs"] = []
  const onExec = options.onExec ?? (() => succeeded)
  const resume = (providerMachineId: string): Promise<void> => {
    const machine = machines.get(providerMachineId)
    if (machine !== undefined) machine.state = "running"
    return Promise.resolve()
  }
  return {
    ...(options.resumable === true ? { resume } : {}),
    id: options.id ?? "e2b",
    displayName: "Fake",
    options: FakeOptions,
    provisionStages: options.boots === true ? ["create", "boot"] : ["create"],
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
      return Promise.resolve({ providerMachineId, platform: options.platform ?? "linux" })
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
