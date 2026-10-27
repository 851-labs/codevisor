import type { EphemeralMachine } from "@codevisor/api"

import { teardownMachine } from "./ephemeral-account.js"
import type { EphemeralMachineDeps } from "./ephemeral-machines.js"

export interface Abandonments {
  readonly abandon: (id: string) => void
  readonly checkpoint: (id: string) => void
  readonly settle: (id: string) => boolean
}

export const ABANDONED_REASON = "Nobody used this machine, so it was torn down"

export const makeAbandonments = (): Abandonments => {
  const ids = new Set<string>()
  return {
    abandon: (id) => {
      ids.add(id)
    },
    checkpoint: (id) => {
      if (ids.has(id)) throw new Error(ABANDONED_REASON)
    },
    settle: (id) => ids.delete(id)
  }
}

export const forgetAbandoned = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine
): Promise<void> => {
  deps.log(`Destroying ephemeral machine ${machine.name} (${machine.id}): nobody used it`)
  if (stillStanding(machine)) {
    await teardownMachine(deps, await deps.providers.get(machine.provider), machine)
  }
  await deps.records.remove(machine.id)
}

const stillStanding = (machine: EphemeralMachine): boolean => machine.state !== "failed"
