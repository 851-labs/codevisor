import type { Sandbox } from "@codevisor/api"
import {
  startServerScript,
  type ProviderMachineState,
  type SandboxProvider
} from "@codevisor/sandboxes"

import { teardownMachine } from "./sandbox-account.js"
import { leavePlaceholder, type RetiredWorkspace } from "./sandbox-placeholder.js"
import { connectionOf } from "./sandbox-profile-record.js"
import { isoNow, remoteWorkspace } from "./sandbox-workspace.js"
import type { SandboxDeps } from "./sandboxes.js"

export const SANDBOX_RESTORE_LABEL = "codevisor-sandbox-restore"

export type PlacedMachine = Sandbox & {
  readonly providerMachineId: string
  readonly machineId: string
}

interface Ending {
  readonly reason: string
  readonly archived?: RetiredWorkspace
}

const unopenedWorkspaceGraceMs = 60 * 60 * 1000

export const isPlaced = (machine: Sandbox): machine is PlacedMachine =>
  machine.state === "ready" &&
  machine.providerMachineId !== undefined &&
  machine.machineId !== undefined

export const watchOne = async (deps: SandboxDeps, machine: PlacedMachine): Promise<void> => {
  const provider = await deps.connections.connect(connectionOf(machine))
  const { state } = await provider.status(machine.providerMachineId)
  if (state === "stopped" && provider.resume !== undefined) {
    await resumeMachine(deps, provider, machine)
    return
  }
  const ending = await endingOf(deps, machine, state)
  if (ending === undefined) return

  deps.log(`Destroying sandbox ${machine.name} (${machine.id}): ${ending.reason}`)
  if (ending.archived === undefined) await teardownRecord(deps, machine)
  else await retireArchived(deps, machine, ending.archived)
}

export const teardownRecord = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  await deps.records.put({ ...machine, state: "destroying" })
  await teardownMachine(deps, await deps.connections.connect(connectionOf(machine)), machine)
  await deps.records.remove(machine.id)
}

const retireArchived = async (
  deps: SandboxDeps,
  machine: PlacedMachine,
  workspace: RetiredWorkspace
): Promise<void> => {
  await deps.records.put({ ...machine, state: "destroying" })
  await teardownMachine(deps, await deps.connections.connect(connectionOf(machine)), machine)
  await leavePlaceholder(deps, machine, workspace)
}

const resumeMachine = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  machine: PlacedMachine
): Promise<void> => {
  deps.log(`Resuming sandbox ${machine.name} (${machine.id})`)
  await provider.resume?.(machine.providerMachineId)
  await provider.exec(machine.providerMachineId, {
    script: startServerScript(deps.bootstrap.serverEnvironment)
  })
}

const endingOf = async (
  deps: SandboxDeps,
  machine: PlacedMachine,
  providerState: ProviderMachineState
): Promise<Ending | undefined> => {
  if (providerState === "gone" || providerState === "stopped") {
    return { reason: `its ${machine.provider} machine ended` }
  }
  const workspace = await remoteWorkspace(deps, machine).catch(() => undefined)
  if (workspace?.state === "active") await noteWorkspaceOpened(deps, machine)
  if (workspace?.state === "archived") {
    return {
      reason: "its workspace was archived",
      archived: { workspaceId: workspace.id, name: workspace.name ?? machine.name }
    }
  }
  if (workspace?.state !== "missing") return undefined

  const reason = missingWorkspaceReason(deps, machine)
  return reason === undefined ? undefined : { reason }
}

const noteWorkspaceOpened = async (deps: SandboxDeps, machine: PlacedMachine): Promise<void> => {
  if (machine.workspaceOpenedAt !== undefined) return

  await deps.records.put({ ...machine, workspaceOpenedAt: isoNow(deps) })
}

const missingWorkspaceReason = (deps: SandboxDeps, machine: PlacedMachine): string | undefined => {
  if (machine.workspaceOpenedAt !== undefined) return "its workspace is gone"
  if (deps.clock.now() - Date.parse(machine.createdAt) < unopenedWorkspaceGraceMs) return undefined
  return "nobody opened its workspace"
}
