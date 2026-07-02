import type { Project } from "@herdman/api"
import { CheckIcon } from "lucide-react"

import { Menu, MenuContent, MenuItem, MenuTrigger } from "../../components/ui/menu"

// The inline project dropdown inside the new-chat title: a quiet pill showing
// the selected project (NewChatView.swift projectMenu).
export function ProjectMenu({
  projects,
  selected,
  onSelect
}: {
  projects: readonly Project[]
  selected: Project | undefined
  onSelect: (project: Project) => void
}) {
  return (
    <Menu>
      <MenuTrigger className="bg-secondary/60 hover:bg-secondary cursor-default rounded-[10px] px-2.5 py-0.5 outline-none">
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
      </MenuContent>
    </Menu>
  )
}
