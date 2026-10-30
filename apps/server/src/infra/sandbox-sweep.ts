import type { Sandbox } from "@codevisor/api"

import { teardownMachine } from "./sandbox-account.js"
import type { SandboxConnection } from "./sandbox-connections.js"
import { createdHere, IN_PROGRESS } from "./sandbox-manager.js"
import { connectionOf } from "./sandbox-profile-record.js"
import type { SandboxDeps } from "./sandboxes.js"

export const failInterrupted = async (
  deps: SandboxDeps,
  busy: ReadonlySet<string>
): Promise<void> => {
  for (const machine of await deps.records.list()) {
    if (!IN_PROGRESS.has(machine.state) || busy.has(machine.id) || !createdHere(deps, machine))
      continue
    const provider = await deps.connections.connect(connectionOf(machine))
    await teardownMachine(deps, provider, machine).catch(() => undefined)
    await deps.records.put({
      ...machine,
      state: "failed",
      error: "Interrupted by a server restart"
    })
  }
}

export const sweepConnection = async (
  deps: SandboxDeps,
  owner: string,
  connection: SandboxConnection
): Promise<void> => {
  const provider = await deps.connections.connect(connection)
  const listed = await provider.list(owner)
  const live = await liveIds(deps)
  for (const orphan of listed) {
    if (live.has(orphan.tags.machine)) continue
    deps.log(
      `Destroying orphaned ${provider.definition.displayName} sandbox ${orphan.providerMachineId}`
    )
    await provider.destroy(orphan.providerMachineId)
  }
}

const liveIds = async (deps: SandboxDeps): Promise<ReadonlySet<string>> =>
  new Set((await deps.records.list()).filter(isLive).map((machine) => machine.id))

const isLive = (machine: Sandbox): boolean =>
  machine.state !== "failed" && machine.state !== "archived"
