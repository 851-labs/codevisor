import type { Project } from "@herdman/api"
import { CheckIcon, FolderPlusIcon } from "lucide-react"

import { Menu, MenuContent, MenuItem, MenuSeparator, MenuTrigger } from "../../components/ui/menu"
import { pickProjectFolder } from "../../lib/folder-picker"
import { useEnsureProject } from "../../lib/queries"

// The inline project dropdown inside the new-chat title: a quiet pill showing
// the selected project (NewChatView.swift projectMenu). The trigger is an
// inline element so the surrounding title wraps as normal text.
export function ProjectMenu({
  projects,
  selected,
  onSelect
}: {
  projects: readonly Project[]
  selected: Project | undefined
  onSelect: (project: Project) => void
}) {
  const ensureProject = useEnsureProject()

  const addProject = async () => {
    const folderPath = await pickProjectFolder()
    if (folderPath == null) return
    try {
      const project = await ensureProject.mutateAsync(folderPath)
      onSelect(project)
    } catch {
      // The projects query surfaces server state; a failed add is retryable.
    }
  }

  return (
    <Menu>
      <MenuTrigger className="bg-secondary/60 hover:bg-secondary inline-flex cursor-default items-center rounded-[10px] px-2.5 py-0.5 align-baseline outline-none">
        {selected?.name ?? "project"}
      </MenuTrigger>
      <MenuContent align="center">
        {projects.map((project) => (
          <MenuItem key={project.id} onClick={() => onSelect(project)}>
            <span className="flex size-4 items-center justify-center">
              {project.id === selected?.id && <CheckIcon className="size-3.5" />}
            </span>
            {project.name}
          </MenuItem>
        ))}
        <MenuSeparator />
        <MenuItem onClick={() => void addProject()}>
          <span className="flex size-4 items-center justify-center">
            <FolderPlusIcon className="size-3.5" />
          </span>
          New project…
        </MenuItem>
      </MenuContent>
    </Menu>
  )
}
