import type { SessionSummary, Project } from "@codevisor/api"
import { Link, useNavigate, useRouterState } from "@tanstack/react-router"
import { ArchiveIcon, FolderIcon } from "lucide-react"
import { useSyncExternalStore } from "react"

import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger
} from "../../components/ui/context-menu"
import { Spinner } from "../../components/ui/spinner"
import { cn } from "../../lib/cn"
import { useUpdateSession } from "../../lib/queries"
import { runningSessionsStore } from "../../lib/running-sessions"
import { relativeTimeShort } from "./relativeTime"
import type { SidebarOrder } from "./sorting"
import { sessionTimestamp } from "./sorting"

export function useIsSessionRunning(sessionId: string): boolean {
  const running = useSyncExternalStore(
    runningSessionsStore.subscribe,
    runningSessionsStore.getSnapshot
  )
  return running.has(sessionId)
}

function useSelectedSessionId(): string | undefined {
  return useRouterState({
    select: (state) => {
      const match = state.matches.find((entry) => entry.routeId === "/_shell/session/$sessionId")
      return match != null ? (match.params as { sessionId: string }).sessionId : undefined
    }
  })
}

export const sidebarRowClassName = cn(
  "group flex w-full cursor-default items-center gap-1.5 rounded-md px-2 py-[5px] text-sm outline-none",
  "hover:bg-[var(--codevisor-row-hover-bg)]"
)

// Fixed-size trailing slot so swapping the timestamp for the spinner or
// archive button on hover doesn't change the row height (SidebarView.swift).
function TrailingSlot({
  session,
  order,
  onArchive
}: {
  session: SessionSummary
  order: SidebarOrder
  onArchive: () => void
}) {
  const isRunning = useIsSessionRunning(session.id)
  return (
    <span className="flex h-4 w-7 shrink-0 items-center justify-end">
      {isRunning ? (
        <Spinner className="size-3" />
      ) : (
        <>
          <button
            type="button"
            aria-label="Archive chat"
            title="Archive chat"
            className="text-muted-foreground hidden group-hover:inline-flex"
            onClick={(mouseEvent) => {
              mouseEvent.preventDefault()
              mouseEvent.stopPropagation()
              onArchive()
            }}
          >
            <ArchiveIcon className="size-3" />
          </button>
          <span className="text-muted-foreground/70 text-[10px] group-hover:hidden">
            {relativeTimeShort(sessionTimestamp(session, order))}
          </span>
        </>
      )}
    </span>
  )
}

function useArchiveSession() {
  const updateSession = useUpdateSession()
  const navigate = useNavigate()
  const selectedSessionId = useSelectedSessionId()
  return (session: SessionSummary) => {
    updateSession.mutate({ id: session.id, request: { isArchived: true } })
    if (selectedSessionId === session.id) {
      void navigate({ to: "/" })
    }
  }
}

// A session row inside an expanded project folder.
export function SessionRow({ session, order }: { session: SessionSummary; order: SidebarOrder }) {
  const selectedSessionId = useSelectedSessionId()
  const archive = useArchiveSession()
  const isSelected = selectedSessionId === session.id
  return (
    <ContextMenu>
      <ContextMenuTrigger
        render={
          <Link
            to="/session/$sessionId"
            params={{ sessionId: session.id }}
            className={cn(
              sidebarRowClassName,
              "text-muted-foreground pl-[30px]",
              isSelected && "text-foreground bg-[var(--codevisor-row-selected-bg)]"
            )}
          >
            <span className="min-w-0 flex-1 truncate">{session.title}</span>
            <TrailingSlot session={session} order={order} onArchive={() => archive(session)} />
          </Link>
        }
      />
      <ContextMenuContent>
        <ContextMenuItem onClick={() => archive(session)}>Archive</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  )
}

// A session row in chronological organization: icon + title + project name.
export function ChronologicalSessionRow({
  session,
  project,
  order
}: {
  session: SessionSummary
  project: Project
  order: SidebarOrder
}) {
  const selectedSessionId = useSelectedSessionId()
  const archive = useArchiveSession()
  const isSelected = selectedSessionId === session.id
  return (
    <ContextMenu>
      <ContextMenuTrigger
        render={
          <Link
            to="/session/$sessionId"
            params={{ sessionId: session.id }}
            className={cn(
              sidebarRowClassName,
              "text-muted-foreground",
              isSelected && "text-foreground bg-[var(--codevisor-row-selected-bg)]"
            )}
          >
            <FolderIcon className="text-muted-foreground size-4 shrink-0" />
            <span className="flex min-w-0 flex-1 flex-col">
              <span className="truncate text-sm">{session.title}</span>
              <span className="text-muted-foreground/70 truncate text-[10px]">{project.name}</span>
            </span>
            <TrailingSlot session={session} order={order} onArchive={() => archive(session)} />
          </Link>
        }
      />
      <ContextMenuContent>
        <ContextMenuItem onClick={() => archive(session)}>Archive</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  )
}
