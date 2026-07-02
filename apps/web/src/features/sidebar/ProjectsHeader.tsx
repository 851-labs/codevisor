import { FolderPlusIcon, ListFilterIcon } from "lucide-react"

import {
  Menu,
  MenuContent,
  MenuGroup,
  MenuGroupLabel,
  MenuRadioGroup,
  MenuRadioItem,
  MenuTrigger
} from "../../components/ui/menu"
import { Tooltip, TooltipContent, TooltipTrigger } from "../../components/ui/tooltip"
import { useEnsureProject } from "../../lib/queries"
import { pickProjectFolder } from "../../lib/folder-picker"
import type { SidebarOrder, SidebarOrganization } from "./sorting"

// "Projects" section header: organize menu (organization + order radio
// groups) and the add-project button (SidebarView.swift projectsHeader).
export function ProjectsHeader({
  organization,
  order,
  onOrganizationChange,
  onOrderChange,
  onProjectAdded
}: {
  organization: SidebarOrganization
  order: SidebarOrder
  onOrganizationChange: (next: SidebarOrganization) => void
  onOrderChange: (next: SidebarOrder) => void
  onProjectAdded: (projectId: string) => void
}) {
  const ensureProject = useEnsureProject()

  const addProject = async () => {
    const folderPath = await pickProjectFolder()
    if (folderPath == null) return
    try {
      const project = await ensureProject.mutateAsync(folderPath)
      onProjectAdded(project.id)
    } catch {
      // The projects query surfaces server state; a failed add is retryable.
    }
  }

  return (
    <div className="mt-3 mb-1 flex items-center gap-1 px-2.5">
      <span className="text-muted-foreground flex-1 text-sm font-semibold">Projects</span>
      <Menu>
        <Tooltip>
          <TooltipTrigger
            render={
              <MenuTrigger
                aria-label="Organize projects"
                className="text-muted-foreground hover:text-foreground inline-flex size-5 items-center justify-center rounded outline-none"
              >
                <ListFilterIcon className="size-4" />
              </MenuTrigger>
            }
          />
          <TooltipContent>Organize projects</TooltipContent>
        </Tooltip>
        <MenuContent align="end">
          <MenuGroup>
            <MenuGroupLabel>Organization</MenuGroupLabel>
            <MenuRadioGroup
              value={organization}
              onValueChange={(value) => {
                if (value === "byProject" || value === "chronological") onOrganizationChange(value)
              }}
            >
              <MenuRadioItem value="byProject">By project</MenuRadioItem>
              <MenuRadioItem value="chronological">Chronological</MenuRadioItem>
            </MenuRadioGroup>
          </MenuGroup>
          <MenuGroup>
            <MenuGroupLabel>Order by</MenuGroupLabel>
            <MenuRadioGroup
              value={order}
              onValueChange={(value) => {
                if (value === "updated" || value === "created") onOrderChange(value)
              }}
            >
              <MenuRadioItem value="updated">Last updated</MenuRadioItem>
              <MenuRadioItem value="created">Created</MenuRadioItem>
            </MenuRadioGroup>
          </MenuGroup>
        </MenuContent>
      </Menu>
      <Tooltip>
        <TooltipTrigger
          render={
            <button
              type="button"
              aria-label="Add a project folder"
              className="text-muted-foreground hover:text-foreground inline-flex size-5 items-center justify-center rounded outline-none"
              onClick={() => void addProject()}
            >
              <FolderPlusIcon className="size-4" />
            </button>
          }
        />
        <TooltipContent>Add a project folder</TooltipContent>
      </Tooltip>
    </div>
  )
}
