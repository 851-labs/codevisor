import type { Workspace } from "@herdman/api"
import { CheckIcon } from "lucide-react"

import { Menu, MenuContent, MenuItem, MenuTrigger } from "../../components/ui/menu"

// The inline project dropdown inside the new-chat title: a quiet pill showing
// the selected workspace (NewChatView.swift projectMenu).
export function ProjectMenu({
  workspaces,
  selected,
  onSelect
}: {
  workspaces: readonly Workspace[]
  selected: Workspace | undefined
  onSelect: (workspace: Workspace) => void
}) {
  return (
    <Menu>
      <MenuTrigger className="bg-secondary/60 hover:bg-secondary cursor-default rounded-[10px] px-2.5 py-0.5 outline-none">
        {selected?.name ?? "project"}
      </MenuTrigger>
      <MenuContent align="center">
        {workspaces.map((workspace) => (
          <MenuItem key={workspace.id} onClick={() => onSelect(workspace)}>
            <span className="flex size-4 items-center justify-center">
              {workspace.id === selected?.id && <CheckIcon className="size-3.5" />}
            </span>
            {workspace.name}
          </MenuItem>
        ))}
      </MenuContent>
    </Menu>
  )
}
