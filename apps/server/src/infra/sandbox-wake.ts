import type { Sandbox } from "@codevisor/api"

import { powerPlanFor, wakeMachine, type SandboxPowerState } from "./sandbox-power.js"
import { connectionOf } from "./sandbox-profile-record.js"
import { isPlaced } from "./sandbox-watch.js"
import type { SandboxDeps } from "./sandboxes.js"

export interface SandboxWaking {
  readonly wakeHere: (machine: Sandbox) => Promise<Sandbox>
  readonly wakeIfRequested: (id: string) => Promise<void>
}

export interface WakeScheduler {
  readonly exclusively: (id: string, work: () => Promise<void>) => Promise<void>
  readonly track: (pipeline: Promise<unknown>) => void
}

export const makeSandboxWaking = (
  deps: SandboxDeps,
  power: SandboxPowerState,
  scheduler: WakeScheduler
): SandboxWaking => {
  const wakeIfRequested = async (id: string): Promise<void> => {
    if (!power.wakeRequests.delete(id)) return

    const machine = await deps.records.get(id)
    if (machine === undefined || !isPlaced(machine) || machine.power === undefined) return

    const provider = await deps.connections.connect(connectionOf(machine))
    const plan = await powerPlanFor(deps, provider, machine)
    if (plan !== undefined) await wakeMachine(deps, plan, machine)
  }

  return {
    wakeHere: (machine) => {
      if (machine.power === undefined) power.activity.set(machine.id, deps.clock.now())
      if (machine.power !== "paused") return Promise.resolve(machine)

      power.wakeRequests.add(machine.id)
      scheduler.track(scheduler.exclusively(machine.id, () => wakeIfRequested(machine.id)))
      return Promise.resolve({ ...machine, power: "waking" })
    },
    wakeIfRequested
  }
}
