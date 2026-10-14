import { dirname } from "node:path"

import type { Project } from "@codevisor/api"
import { repoIdentityKey } from "@codevisor/api"
import { scratchWorkspacesRoot } from "@codevisor/db"
import { isGitWorkTree } from "@codevisor/worktrees"

import { existingDirectory } from "../server-context.js"

export const probeProject = async (serverId: string, project: Project): Promise<Project> => {
  const isScratch = isScratchProject(project)
  return {
    ...project,
    ...(() => {
      const repoKey = project.repoUrl === undefined ? undefined : repoIdentityKey(project.repoUrl)
      return repoKey === undefined ? {} : { repoKey }
    })(),
    locations: await Promise.all(
      project.locations.map(async (location) =>
        location.serverId === serverId && existingDirectory(location.folderPath) !== undefined
          ? {
              ...location,
              isGitRepository: isScratch ? false : await isGitWorkTree(location.folderPath)
            }
          : location
      )
    ),
    ...(isScratch ? { isScratch: true } : {})
  }
}

export const isScratchProject = (project: Project): boolean =>
  project.locations.some((location) => dirname(location.folderPath) === scratchWorkspacesRoot())
