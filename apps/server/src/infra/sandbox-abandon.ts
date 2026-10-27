import type { Sandbox } from "@codevisor/api"

import { teardownMachine } from "./sandbox-account.js"
import type { SandboxDeps } from "./sandboxes.js"

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

export const forgetAbandoned = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  deps.log(`Destroying sandbox ${machine.name} (${machine.id}): nobody used it`)
  if (stillStanding(machine)) {
    await teardownMachine(deps, await deps.providers.get(machine.provider), machine)
  }
  await deps.records.remove(machine.id)
}

const stillStanding = (machine: Sandbox): boolean => machine.state !== "failed"
