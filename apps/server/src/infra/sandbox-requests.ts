import type { CreateSandboxRequest, Sandbox, SandboxProfile } from "@codevisor/api"
import type { ProvisionPlan } from "@codevisor/sandboxes"

import { HttpFailure } from "../server-context.js"
import { optionalLinks, profileRecordFields } from "./sandbox-profile-record.js"
import { isoNow } from "./sandbox-workspace.js"
import type { SandboxDeps } from "./sandboxes.js"

export const harnessOf = (request: CreateSandboxRequest): { readonly harnessId?: string } => {
  const harnessId = request.harnessId ?? request.agent?.harness
  return harnessId === undefined ? {} : { harnessId }
}

export const retryRequest = (failed: Sandbox): CreateSandboxRequest => {
  if (failed.state !== "failed") throw new HttpFailure(409, `${failed.name} hasn't failed`)
  if (failed.profileId === undefined) {
    throw new HttpFailure(409, `${failed.name} has no profile to start from again`)
  }
  return {
    id: failed.id,
    profileId: failed.profileId,
    projectId: failed.projectId,
    name: failed.name,
    ...optionalLinks(failed, ["projectName", "repoUrl", "workspaceId", "harnessId"]),
    ...(failed.agent === undefined ? {} : { agent: failed.agent }),
    ...(failed.defersWorkspace === true ? { defersWorkspace: true } : {})
  }
}

export const restoreRequest = (
  archived: Sandbox,
  profileId: string,
  workspaceId: string
): CreateSandboxRequest => {
  return {
    profileId,
    projectId: archived.projectId,
    name: archived.name,
    workspaceId,
    ...optionalLinks(archived, ["projectName", "repoUrl"])
  }
}

export const restoredFields = (archived: Sandbox): Partial<Sandbox> => ({
  restoresWorkspace: true,
  ...(archived.workspaceName === undefined ? {} : { workspaceName: archived.workspaceName })
})

export const newRecord = (
  deps: SandboxDeps,
  request: CreateSandboxRequest,
  profile: SandboxProfile,
  plan: ProvisionPlan
): Sandbox => {
  const id = request.id?.toLowerCase() ?? deps.newId()
  return {
    id,
    name: request.name?.trim() || `${profile.name} ${id.slice(0, 8)}`,
    projectId: request.projectId,
    ...projectSourceOf(request),
    ...profileRecordFields(profile),
    state: "creating",
    createdAt: isoNow(deps),
    createdOn: deps.serverId,
    plan: [
      ...plan.stages,
      ...(plan.preinstalled ? [] : ["install" as const]),
      "signIn",
      "sync",
      "clone"
    ],
    ...(request.workspaceId === undefined
      ? {}
      : { workspaceId: request.workspaceId.toLowerCase() }),
    ...(defersWorkspace(request) ? { defersWorkspace: true } : {}),
    ...harnessOf(request),
    ...(request.agent === undefined ? {} : { agent: request.agent })
  }
}

const projectSourceOf = (request: CreateSandboxRequest) => ({
  ...(request.projectName === undefined ? {} : { projectName: request.projectName }),
  ...(request.repoUrl === undefined ? {} : { repoUrl: request.repoUrl })
})

const defersWorkspace = (request: CreateSandboxRequest): boolean =>
  (request.defersWorkspace === true || request.agent !== undefined) &&
  request.workspaceId === undefined
