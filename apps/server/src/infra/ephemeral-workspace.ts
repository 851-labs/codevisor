import type { EphemeralMachine, Project } from "@codevisor/api"

import type { EphemeralMachineDeps } from "./ephemeral-machines.js"

export const EPHEMERAL_WORKSPACE_LABEL = "codevisor-ephemeral"

export interface PlacedWorkspace {
  readonly remoteProjectId: string
  readonly workspaceId: string
}

export type RemoteWorkspaceState = "active" | "archived" | "missing"

export const placeWorkspace = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine & { readonly machineId: string }
): Promise<PlacedWorkspace> => {
  const project = await deps.projects.get(machine.projectId)
  if (project === undefined) throw new Error(`No project ${machine.projectId} on this machine`)

  const remoteProjectId = await remoteProjectFor(deps, machine.machineId, project)
  const workspaceId = deps.newId()
  await deps.remoteTools.call(machine.machineId, "codevisor.workspaces.upsert", {
    workspaceId,
    projectId: remoteProjectId,
    name: machine.name,
    hasCustomName: true,
    labels: { [EPHEMERAL_WORKSPACE_LABEL]: machine.id }
  })
  return { remoteProjectId, workspaceId }
}

export const remoteWorkspaceState = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine & { readonly machineId: string }
): Promise<RemoteWorkspaceState> => {
  const listed = await deps.remoteTools.call(machine.machineId, "codevisor.workspaces.list", {
    label: `${EPHEMERAL_WORKSPACE_LABEL}=${machine.id}`
  })
  const workspace = workspacesIn(listed).find((candidate) => candidate.id === machine.workspaceId)
  if (workspace === undefined) return "missing"

  return workspace.isArchived === true ? "archived" : "active"
}

const remoteProjectFor = async (
  deps: EphemeralMachineDeps,
  machineId: string,
  project: Project
): Promise<string> => {
  if (project.repoUrl === undefined) {
    return idOf(await deps.remoteTools.call(machineId, "codevisor.projects.create_scratch", {}))
  }
  return idOf(
    await deps.remoteTools.call(machineId, "codevisor.projects.clone", {
      url: project.repoUrl,
      name: project.name,
      ...(project.worktreeBase === undefined ? {} : { worktreeBase: project.worktreeBase }),
      ...(project.defaultRunLocation === undefined
        ? {}
        : { defaultRunLocation: project.defaultRunLocation })
    })
  )
}

interface ListedWorkspace {
  readonly id: string
  readonly isArchived?: unknown
}

const workspacesIn = (listed: unknown): ReadonlyArray<ListedWorkspace> => {
  if (!Array.isArray(listed)) throw new Error("The ephemeral machine didn't list its workspaces")
  return listed.filter(isListedWorkspace)
}

const isListedWorkspace = (item: unknown): item is ListedWorkspace =>
  isRecord(item) && typeof item.id === "string"

const idOf = (project: unknown): string => {
  if (isRecord(project) && typeof project.id === "string") return project.id
  throw new Error("The ephemeral machine didn't return a project id")
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
