import { ProjectRecommendation, type FirstRunFolder } from "@codevisor/api"
import { Schema } from "effect"

import type { HeldProject } from "./project-recommendations.js"
import type { ProtectedFolder } from "./protected-folders.js"
import { run, type CodevisorServerServices } from "./server-context.js"

export interface PendingFolder extends ProtectedFolder {
  readonly projects: ReadonlyArray<ProjectRecommendation>
}

export interface PendingFolders {
  readonly remaining: number
  readonly folders: ReadonlyArray<PendingFolder>
}

export const noPendingFolders: PendingFolders = { remaining: 0, folders: [] }

export const groupByFolder = (held: ReadonlyArray<HeldProject>): ReadonlyArray<PendingFolder> => {
  const folders = new Map<string, PendingFolder>()
  for (const { folder, project } of held) {
    const projects = folders.get(folder.id)?.projects ?? []
    folders.set(folder.id, { ...folder, projects: [...projects, project] })
  }
  return [...folders.values()]
}

export const readPendingFolders = async (
  services: CodevisorServerServices
): Promise<PendingFolders> => {
  const stored = await run(services.db.getMachineSetting(pendingFoldersSetting))
  return stored === undefined ? noPendingFolders : decodePendingFolders(stored)
}

export const savePendingFolders = (
  services: CodevisorServerServices,
  pending: PendingFolders
): Promise<void> => {
  const stored = pending.folders.length === 0 ? undefined : JSON.stringify(pending)
  return run(services.db.setMachineSetting(pendingFoldersSetting, stored))
}

export const foldersToAsk = (pending: PendingFolders): ReadonlyArray<FirstRunFolder> =>
  pending.folders.map((folder) => ({
    id: folder.id,
    name: folder.name,
    path: folder.path,
    projects: folder.projects.map((project) => project.name)
  }))

export const withoutFolder = (pending: PendingFolders, folderId: string): PendingFolders => ({
  ...pending,
  folders: pending.folders.filter((folder) => folder.id !== folderId)
})

const pendingFoldersSetting = "first-run-folders"

const StoredPendingFolders = Schema.Struct({
  remaining: Schema.Number,
  folders: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      path: Schema.String,
      projects: Schema.Array(ProjectRecommendation)
    })
  )
})

const decodeStored = Schema.decodeUnknownOption(StoredPendingFolders)

const decodePendingFolders = (stored: string): PendingFolders => {
  try {
    const decoded = decodeStored(JSON.parse(stored))
    return decoded._tag === "Some" ? decoded.value : noPendingFolders
  } catch {
    return noPendingFolders
  }
}
