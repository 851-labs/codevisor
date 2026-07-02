import type { SessionSummary } from "@herdman/api"
import { Link } from "@tanstack/react-router"
import { SquarePenIcon } from "lucide-react"
import { useMemo, useState } from "react"

import { ScrollArea } from "../../components/ui/scroll-area"
import { cn } from "../../lib/cn"
import { useLocalStorage } from "../../lib/useLocalStorage"
import { useSessions, useWorkspaces } from "../../lib/queries"
import { ThemePicker } from "../theme/ThemePicker"
import { ProjectsHeader } from "./ProjectsHeader"
import { ChronologicalSessionRow, sidebarRowClassName } from "./SessionRow"
import {
  compareSessions,
  orderWorkspaces,
  type SidebarOrder,
  type SidebarOrganization
} from "./sorting"
import { WorkspaceFolder } from "./WorkspaceFolder"

function narrowOrganization(raw: string): SidebarOrganization {
  return raw === "chronological" ? "chronological" : "byProject"
}

function narrowOrder(raw: string): SidebarOrder {
  return raw === "created" ? "created" : "updated"
}

// The sidebar: a New Chat action, a Projects section listing workspace
// folders and their sessions (or a flat chronological session list), and the
// theme picker footer (the slot the macOS app gives its machine picker).
export function Sidebar() {
  const workspacesQuery = useWorkspaces()
  const sessionsQuery = useSessions()
  const [organizationRaw, setOrganizationRaw] = useLocalStorage(
    "herdman-sidebar-organization",
    "byProject"
  )
  const [orderRaw, setOrderRaw] = useLocalStorage("herdman-sidebar-order", "updated")
  const [manualOrderRaw] = useLocalStorage("herdman-sidebar-project-order", "")
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set())

  const organization = narrowOrganization(organizationRaw)
  const order = narrowOrder(orderRaw)

  const activeWorkspaces = useMemo(
    () => (workspacesQuery.data ?? []).filter((workspace) => !workspace.isArchived),
    [workspacesQuery.data]
  )

  const sessionsByWorkspace = useMemo(() => {
    const map = new Map<string, SessionSummary[]>()
    for (const session of sessionsQuery.data ?? []) {
      if (session.isArchived) continue
      const bucket = map.get(session.workspaceId)
      if (bucket == null) map.set(session.workspaceId, [session])
      else bucket.push(session)
    }
    for (const bucket of map.values()) {
      bucket.sort((left, right) => compareSessions(left, right, order))
    }
    return map
  }, [sessionsQuery.data, order])

  const visibleWorkspaces = useMemo(() => {
    const manualOrder =
      organization === "byProject" ? manualOrderRaw.split("\n").filter(Boolean) : []
    return orderWorkspaces(activeWorkspaces, manualOrder, sessionsByWorkspace, order)
  }, [activeWorkspaces, manualOrderRaw, organization, sessionsByWorkspace, order])

  const chronologicalSessions = useMemo(() => {
    if (organization !== "chronological") return []
    return visibleWorkspaces
      .flatMap((workspace) =>
        (sessionsByWorkspace.get(workspace.id) ?? []).map((session) => ({ session, workspace }))
      )
      .sort((left, right) => compareSessions(left.session, right.session, order))
  }, [organization, visibleWorkspaces, sessionsByWorkspace, order])

  const toggleExpanded = (id: string) => {
    setExpanded((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const expandWorkspace = (id: string) => {
    setExpanded((current) => new Set(current).add(id))
  }

  return (
    <aside className="border-border-opaque bg-sidebar flex h-full w-full flex-col border-r">
      <ScrollArea className="min-h-0 flex-1">
        <nav className="flex flex-col gap-px p-2">
          <Link to="/" search={{}} className={cn(sidebarRowClassName, "text-foreground")}>
            <SquarePenIcon className="text-muted-foreground size-4 shrink-0" />
            <span>New chat</span>
          </Link>

          <ProjectsHeader
            organization={organization}
            order={order}
            onOrganizationChange={(next) => setOrganizationRaw(next)}
            onOrderChange={(next) => setOrderRaw(next)}
            onWorkspaceAdded={expandWorkspace}
          />

          {organization === "byProject" ? (
            visibleWorkspaces.map((workspace) => (
              <WorkspaceFolder
                key={workspace.id}
                workspace={workspace}
                sessions={sessionsByWorkspace.get(workspace.id) ?? []}
                order={order}
                expanded={expanded.has(workspace.id)}
                onToggle={toggleExpanded}
              />
            ))
          ) : (
            <>
              {chronologicalSessions.map(({ session, workspace }) => (
                <ChronologicalSessionRow
                  key={session.id}
                  session={session}
                  workspace={workspace}
                  order={order}
                />
              ))}
              {chronologicalSessions.length === 0 && visibleWorkspaces.length > 0 && (
                <p className="text-muted-foreground/70 px-2.5 py-1 text-xs">No sessions yet</p>
              )}
            </>
          )}
          {visibleWorkspaces.length === 0 && (
            <p className="text-muted-foreground/70 px-2.5 py-1 text-xs">Add a workspace with +</p>
          )}
        </nav>
      </ScrollArea>
      <div className="border-border-opaque border-t p-2">
        <ThemePicker />
      </div>
    </aside>
  )
}
