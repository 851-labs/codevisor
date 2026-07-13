import type { SessionSummary } from "@codevisor/api"
import { Link } from "@tanstack/react-router"
import { BlocksIcon, SquarePenIcon } from "lucide-react"
import { useMemo, useState } from "react"

import { ScrollArea } from "../../components/ui/scroll-area"
import { cn } from "../../lib/cn"
import { useLocalStorage } from "../../lib/useLocalStorage"
import { useSessions, useProjects } from "../../lib/queries"
import { ThemePicker } from "../theme/ThemePicker"
import { ProjectsHeader } from "./ProjectsHeader"
import { ChronologicalSessionRow, sidebarRowClassName } from "./SessionRow"
import {
  compareSessions,
  orderProjects,
  type SidebarOrder,
  type SidebarOrganization
} from "./sorting"
import { ProjectFolder } from "./ProjectFolder"

function narrowOrganization(raw: string): SidebarOrganization {
  return raw === "chronological" ? "chronological" : "byProject"
}

function narrowOrder(raw: string): SidebarOrder {
  return raw === "created" ? "created" : "updated"
}

// The sidebar: a New Chat action, a Projects section listing project
// folders and their sessions (or a flat chronological session list), and the
// theme picker footer (the slot the macOS app gives its machine picker).
export function Sidebar() {
  const projectsQuery = useProjects()
  const sessionsQuery = useSessions()
  const [organizationRaw, setOrganizationRaw] = useLocalStorage(
    "codevisor-sidebar-organization",
    "byProject"
  )
  const [orderRaw, setOrderRaw] = useLocalStorage("codevisor-sidebar-order", "updated")
  const [manualOrderRaw] = useLocalStorage("codevisor-sidebar-project-order", "")
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set())

  const organization = narrowOrganization(organizationRaw)
  const order = narrowOrder(orderRaw)

  const activeProjects = useMemo(
    () => (projectsQuery.data ?? []).filter((project) => !project.isArchived),
    [projectsQuery.data]
  )

  const sessionsByProject = useMemo(() => {
    const map = new Map<string, SessionSummary[]>()
    for (const session of sessionsQuery.data ?? []) {
      if (session.isArchived) continue
      const bucket = map.get(session.projectId)
      if (bucket == null) map.set(session.projectId, [session])
      else bucket.push(session)
    }
    for (const bucket of map.values()) {
      bucket.sort((left, right) => compareSessions(left, right, order))
    }
    return map
  }, [sessionsQuery.data, order])

  const visibleProjects = useMemo(() => {
    const manualOrder =
      organization === "byProject" ? manualOrderRaw.split("\n").filter(Boolean) : []
    return orderProjects(activeProjects, manualOrder, sessionsByProject, order)
  }, [activeProjects, manualOrderRaw, organization, sessionsByProject, order])

  const chronologicalSessions = useMemo(() => {
    if (organization !== "chronological") return []
    return visibleProjects
      .flatMap((project) =>
        (sessionsByProject.get(project.id) ?? []).map((session) => ({ session, project }))
      )
      .sort((left, right) => compareSessions(left.session, right.session, order))
  }, [organization, visibleProjects, sessionsByProject, order])

  const toggleExpanded = (id: string) => {
    setExpanded((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const expandProject = (id: string) => {
    setExpanded((current) => new Set(current).add(id))
  }

  return (
    <aside className="flex h-full w-full flex-col">
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
            onProjectAdded={expandProject}
          />

          {organization === "byProject" ? (
            visibleProjects.map((project) => (
              <ProjectFolder
                key={project.id}
                project={project}
                sessions={sessionsByProject.get(project.id) ?? []}
                order={order}
                expanded={expanded.has(project.id)}
                onToggle={toggleExpanded}
              />
            ))
          ) : (
            <>
              {chronologicalSessions.map(({ session, project }) => (
                <ChronologicalSessionRow
                  key={session.id}
                  session={session}
                  project={project}
                  order={order}
                />
              ))}
              {chronologicalSessions.length === 0 && visibleProjects.length > 0 && (
                <p className="text-muted-foreground/70 px-2.5 py-1 text-xs">No sessions yet</p>
              )}
            </>
          )}
          {visibleProjects.length === 0 && (
            <p className="text-muted-foreground/70 px-2.5 py-1 text-xs">Add a project with +</p>
          )}
        </nav>
      </ScrollArea>
      <div className="border-border-opaque border-t p-2">
        <Link
          to="/internal/storybook"
          className={cn(sidebarRowClassName, "text-muted-foreground mb-1")}
          activeProps={{
            className: "text-foreground bg-[var(--codevisor-row-selected-bg)]"
          }}
        >
          <BlocksIcon className="text-muted-foreground size-4 shrink-0" />
          <span>Internal UI</span>
        </Link>
        <ThemePicker />
      </div>
    </aside>
  )
}
