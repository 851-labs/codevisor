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
export const probeProject = async (serverId: string, project: Project): Promise<Project> => ({
  ...project,
  ...(() => {
    const repoKey = project.repoUrl === undefined ? undefined : repoIdentityKey(project.repoUrl)
    return repoKey === undefined ? {} : { repoKey }
  })(),
  locations: await Promise.all(
    project.locations.map(async (location) =>
      location.serverId === serverId && existingDirectory(location.folderPath) !== undefined
        ? { ...location, isGitRepository: await isGitWorkTree(location.folderPath) }
        : location
    )
  ),
  ...(project.locations.some((location) => dirname(location.folderPath) === scratchWorkspacesRoot())
    ? { isScratch: true }
    : {})
})
