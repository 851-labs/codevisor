import type { SessionSummary, Workspace } from "@herdman/api"
import { useNavigate } from "@tanstack/react-router"
import { ChevronRightIcon, FolderIcon, SquarePenIcon } from "lucide-react"

import { Collapsible, CollapsiblePanel, CollapsibleTrigger } from "../../components/ui/collapsible"
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger
} from "../../components/ui/context-menu"
import { cn } from "../../lib/cn"
import { useUpdateWorkspace } from "../../lib/queries"
import { SessionRow, sidebarRowClassName } from "./SessionRow"
import type { SidebarOrder } from "./sorting"

// An expandable workspace folder row and its session rows. On hover the
// project icon swaps for a disclosure chevron and a "new chat here" pencil
// appears (SidebarView.swift workspaceFolder).
export function WorkspaceFolder({
  workspace,
  sessions,
  order,
  expanded,
  onToggle
}: {
  workspace: Workspace
  sessions: readonly SessionSummary[]
  order: SidebarOrder
  expanded: boolean
  onToggle: (id: string) => void
}) {
  const navigate = useNavigate()
  const updateWorkspace = useUpdateWorkspace()

  const newChatHere = () => {
    void navigate({ to: "/", search: { workspace: workspace.id } })
  }

  return (
    <Collapsible open={expanded} onOpenChange={() => onToggle(workspace.id)}>
      <ContextMenu>
        <ContextMenuTrigger
          render={
            <div className={cn(sidebarRowClassName, "font-medium")} title={workspace.folderPath}>
              <CollapsibleTrigger className="flex min-w-0 flex-1 items-center gap-1.5 outline-none">
                <span className="relative flex size-4 shrink-0 items-center justify-center">
                  <FolderIcon className="text-muted-foreground size-4 group-hover:opacity-0" />
                  <ChevronRightIcon
                    className={cn(
                      "text-muted-foreground absolute size-3.5 opacity-0 transition-transform group-hover:opacity-100",
                      expanded && "rotate-90"
                    )}
                  />
                </span>
                <span className="min-w-0 flex-1 truncate text-left">{workspace.name}</span>
              </CollapsibleTrigger>
              <button
                type="button"
                aria-label={`New chat in ${workspace.name}`}
                title={`New chat in ${workspace.name}`}
                className="text-muted-foreground hidden shrink-0 group-hover:inline-flex"
                onClick={newChatHere}
              >
                <SquarePenIcon className="size-3.5" />
              </button>
            </div>
          }
        />
        <ContextMenuContent>
          <ContextMenuItem onClick={newChatHere}>New chat here</ContextMenuItem>
          <ContextMenuItem
            onClick={() =>
              updateWorkspace.mutate({ id: workspace.id, request: { isArchived: true } })
            }
          >
            Archive
          </ContextMenuItem>
        </ContextMenuContent>
      </ContextMenu>
      <CollapsiblePanel>
        {sessions.map((session) => (
          <SessionRow key={session.id} session={session} order={order} />
        ))}
        {sessions.length === 0 && (
          <p className="text-muted-foreground/70 py-1 pl-[30px] text-xs">No sessions yet</p>
        )}
      </CollapsiblePanel>
    </Collapsible>
  )
}
