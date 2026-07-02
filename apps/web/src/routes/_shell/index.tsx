import { createFileRoute } from "@tanstack/react-router"

import { NewChatScreen } from "../../features/new-chat/NewChatScreen"

interface NewChatSearch {
  project?: string
}

export const Route = createFileRoute("/_shell/")({
  validateSearch: (search: Record<string, unknown>): NewChatSearch => ({
    project: typeof search.project === "string" ? search.project : undefined
  }),
  component: NewChatRoute
})

function NewChatRoute() {
  const { project } = Route.useSearch()
  // Remount when the preferred project changes so the local selection reset
  // mirrors the Swift `.task(id: preferredProjectId)` behavior.
  return <NewChatScreen key={project ?? "none"} preferredProjectId={project} />
}
