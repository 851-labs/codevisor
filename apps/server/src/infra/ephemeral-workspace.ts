import type { EphemeralMachine, Project } from "@codevisor/api"

import type { EphemeralMachineDeps } from "./ephemeral-machines.js"

export const EPHEMERAL_WORKSPACE_LABEL = "codevisor-ephemeral"

export interface PlacedWorkspace {
  readonly remoteProjectId: string
  readonly workspaceId: string
  readonly workspaceOpenedAt?: string
}

export type RemoteWorkspaceState = "active" | "archived" | "missing"

export const placeWorkspace = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine & { readonly machineId: string },
  log: (line: string) => void
): Promise<PlacedWorkspace> => {
  const project = await deps.projects.get(machine.projectId)
  if (project === undefined) throw new Error(`No project ${machine.projectId} on this machine`)

  log(project.repoUrl === undefined ? "Creating an empty project" : `Cloning ${project.repoUrl}`)
  const remoteProjectId = await remoteProjectFor(deps, machine.machineId, project)
  log(`${project.name} is ready`)
  if (machine.workspaceId !== undefined)
    return { remoteProjectId, workspaceId: machine.workspaceId }

  const workspaceId = deps.newId()
  await deps.remoteTools.call(machine.machineId, "codevisor.workspaces.upsert", {
    workspaceId,
    projectId: remoteProjectId,
    name: machine.name,
    hasCustomName: true,
    labels: { [EPHEMERAL_WORKSPACE_LABEL]: machine.id }
  })
  return { remoteProjectId, workspaceId, workspaceOpenedAt: isoNow(deps) }
}

export const remoteWorkspaceState = async (
  deps: EphemeralMachineDeps,
  machine: EphemeralMachine & { readonly machineId: string }
): Promise<RemoteWorkspaceState> => {
  const listed = await deps.remoteTools.call(machine.machineId, "codevisor.workspaces.list", {})
  const workspace = workspacesIn(listed).find((candidate) =>
    sameId(candidate.id, machine.workspaceId)
  )
  if (workspace === undefined) return "missing"

  return workspace.isArchived ? "archived" : "active"
}

export const isoNow = (deps: EphemeralMachineDeps): string =>
  new Date(deps.clock.now()).toISOString()

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
  readonly isArchived: boolean
}

const workspacesIn = (listed: unknown): ReadonlyArray<ListedWorkspace> => {
  const items = Array.isArray(listed) ? listed : recordField(listed, "items")
  if (!Array.isArray(items)) throw new Error("The ephemeral machine didn't list its workspaces")
  return items.flatMap(listedWorkspace)
}

const listedWorkspace = (item: unknown): ReadonlyArray<ListedWorkspace> => {
  const id = idIn(item, "workspaceId")
  if (id === undefined) return []
  return [{ id, isArchived: recordField(item, "isArchived") === true }]
}

const idOf = (project: unknown): string => {
  const id = idIn(project, "projectId")
  if (id === undefined) throw new Error("The ephemeral machine didn't return a project id")
  return id
}

const idIn = (value: unknown, namedKey: string): string | undefined => {
  const id = recordField(value, namedKey) ?? recordField(value, "id")
  return typeof id === "string" ? id : undefined
}

const sameId = (left: string, right: string | undefined): boolean =>
  left.toLowerCase() === right?.toLowerCase()

const recordField = (value: unknown, key: string): unknown =>
  isRecord(value) ? value[key] : undefined

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
