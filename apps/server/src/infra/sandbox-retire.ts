import type { Sandbox } from "@codevisor/api"

import { teardownMachine } from "./sandbox-account.js"
import { leavePlaceholder } from "./sandbox-placeholder.js"
import { connectionOf } from "./sandbox-profile-record.js"
import { teardownRecord } from "./sandbox-watch.js"
import { remoteWorkspace } from "./sandbox-workspace.js"
import type { SandboxDeps } from "./sandboxes.js"

export const retainProviderAccounts = async (deps: SandboxDeps): Promise<void> => {
  const records = await deps.records.list()
  await deps.providerAccounts.retain(new Set(records.flatMap(accountIdOf)))
}

export const usingProvider = async (
  deps: SandboxDeps,
  accountId: string
): Promise<ReadonlyArray<Sandbox>> =>
  (await deps.records.list()).filter(
    (machine) => machine.accountId === accountId && machine.state !== "archived"
  )

export const withDeletedProvider = async (deps: SandboxDeps): Promise<ReadonlyArray<Sandbox>> => {
  const standing = (await deps.records.list()).filter(isStanding)
  const deleted = await Promise.all(standing.map((machine) => providerDeleted(deps, machine)))
  return standing.filter((_, index) => deleted[index])
}

export const retireMachine = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  if (machine.state === "failed") return deps.records.remove(machine.id)
  if (machine.workspaceId === undefined) return teardownRecord(deps, machine)

  return retireWithWorkspace(deps, machine, machine.workspaceId)
}

export const retireOrphan = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  try {
    await retireMachine(deps, machine)
  } catch (cause) {
    deps.log(`Tearing down sandbox ${machine.name} (${machine.id}) failed: ${messageOf(cause)}`)
    if (await credentialsKept(deps, machine)) return

    await deps.records.put({ ...machine, state: "failed", error: strandedReason(machine) })
  }
}

const retireWithWorkspace = async (
  deps: SandboxDeps,
  machine: Sandbox,
  workspaceId: string
): Promise<void> => {
  const name = await workspaceName(deps, machine)
  await deps.records.put({ ...machine, state: "destroying" })
  await teardownMachine(deps, await deps.connections.connect(connectionOf(machine)), machine)
  const { profileId: _unrestorable, ...retired } = machine
  await leavePlaceholder(deps, retired, { workspaceId, name })
}

const workspaceName = async (deps: SandboxDeps, machine: Sandbox): Promise<string> => {
  const fallback = machine.workspaceName ?? machine.name
  if (machine.machineId === undefined) return fallback

  const remote = await remoteWorkspace(deps, { ...machine, machineId: machine.machineId }).catch(
    () => undefined
  )
  if (remote === undefined || remote.state === "missing") return fallback
  return remote.name ?? fallback
}

const providerDeleted = async (deps: SandboxDeps, machine: Sandbox): Promise<boolean> =>
  machine.accountId !== undefined && !(await deps.providerAccounts.exists(machine.accountId))

const credentialsKept = async (deps: SandboxDeps, machine: Sandbox): Promise<boolean> =>
  machine.accountId !== undefined &&
  (await deps.providerAccounts.account(machine.accountId)) !== undefined

const strandedReason = (machine: Sandbox): string => {
  const vendorMachine = machine.providerMachineId ?? "its machine"
  return `Its ${machine.provider} provider was deleted before this Mac could tear it down. Delete ${vendorMachine} in your ${machine.provider} account.`
}

const isStanding = (machine: Sandbox): boolean =>
  machine.state !== "failed" && machine.state !== "archived"

const accountIdOf = (machine: Sandbox): ReadonlyArray<string> =>
  machine.accountId === undefined ? [] : [machine.accountId]

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
