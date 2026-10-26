import type { CloudMachinePresence, EphemeralMachine } from "@codevisor/api"
import { bootstrapMachine, type EphemeralProvider } from "@codevisor/ephemeral-machines"

import type { EphemeralMachineDeps } from "./ephemeral-machines.js"
import type { EphemeralSetupProgress } from "./ephemeral-setup-log.js"

export interface JoinedMachine {
  readonly deviceId: string
  readonly machineId: string
}

const joinTimeoutMs = 3 * 60 * 1000
const joinPollMs = 1000

export const joinAccount = async (
  deps: EphemeralMachineDeps,
  provider: EphemeralProvider,
  machine: EphemeralMachine & { readonly providerMachineId: string },
  setup: EphemeralSetupProgress
): Promise<JoinedMachine> => {
  const owner = requireOwner(deps)
  const before = presentDeviceIds(deps)
  const inviteCode = await deps.account.invite(machine.provider)
  setup.redact(inviteCode)
  const result = await bootstrapMachine(
    provider,
    machine.providerMachineId,
    { inviteCode, machineName: machine.name, ...deps.bootstrap },
    setup.output
  )
  if (!provider.streamsOutput) replayOutput(setup, result)
  setup.flush()
  setup.log(`Waiting for ${machine.name} to join your account`)
  const joined = await waitForJoined(deps, { owner, name: machine.name, before })
  setup.log(`${machine.name} joined your account`)
  return joined
}

const replayOutput = (
  setup: EphemeralSetupProgress,
  result: { readonly stdout: string; readonly stderr: string }
): void => {
  setup.output("stdout", result.stdout)
  setup.output("stderr", result.stderr)
}

export const teardownMachine = async (
  deps: EphemeralMachineDeps,
  provider: EphemeralProvider,
  machine: EphemeralMachine
): Promise<void> => {
  if (machine.deviceId !== undefined) await deps.account.remove(machine.deviceId)
  if (machine.providerMachineId !== undefined) await provider.destroy(machine.providerMachineId)
}

export const requireOwner = (deps: EphemeralMachineDeps): string => {
  const owner = deps.account.ownerDeviceId()
  if (owner === undefined) throw new Error("Connect this machine to your Codevisor account first")
  return owner
}

const presentDeviceIds = (deps: EphemeralMachineDeps): ReadonlySet<string> =>
  new Set(deps.account.presences().map((presence) => presence.deviceId))

interface JoinExpectation {
  readonly owner: string
  readonly name: string
  readonly before: ReadonlySet<string>
}

const waitForJoined = async (
  deps: EphemeralMachineDeps,
  expected: JoinExpectation
): Promise<JoinedMachine> => {
  const deadline = deps.clock.now() + joinTimeoutMs
  while (deps.clock.now() < deadline) {
    const joined = deps.account.presences().find((presence) => isNewlyJoined(presence, expected))
    if (joined !== undefined) return { deviceId: joined.deviceId, machineId: machineIdOf(joined) }
    await deps.clock.sleep(joinPollMs)
  }
  throw new Error("Codevisor was installed, but the machine never came online on the account")
}

const isNewlyJoined = (presence: CloudMachinePresence, expected: JoinExpectation): boolean =>
  presence.online &&
  presence.name === expected.name &&
  presence.addedBy?.deviceId === expected.owner &&
  !expected.before.has(presence.deviceId)

const machineIdOf = (presence: CloudMachinePresence): string =>
  presence.serverId ?? `cloud:${presence.deviceId}`
