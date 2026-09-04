import type { Project } from "@codevisor/api"
import { repoIdentityKey } from "@codevisor/api"
import { scratchWorkspacesRoot } from "@codevisor/db"
import { dirname } from "node:path"
import { isGitWorkTree } from "@codevisor/worktrees"
import { existingDirectory } from "../server-context.js"

/// Annotates this server's locations with whether their folder is a git
/// repository so clients can decide if the worktree option is available,
/// derives the cross-machine `repoKey` from the stored remote, and marks
/// scratch-workspace backing projects (folder under ~/codevisor/workspaces)
/// so clients can hide them from project pickers.
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
              // A scratch folder is never the project's repository, even
              // when the scratch root happens to sit inside someone's
              // checkout (`git rev-parse` would answer for the parent).
              isGitRepository: isScratch ? false : await isGitWorkTree(location.folderPath)
            }
          : location
      )
    ),
    ...(isScratch ? { isScratch: true } : {})
  }
}

/// Whether the project is the hidden backing project of a scratch
/// workspace: its folder lives directly under ~/codevisor/workspaces.
export const isScratchProject = (project: Project): boolean =>
  project.locations.some((location) => dirname(location.folderPath) === scratchWorkspacesRoot())
