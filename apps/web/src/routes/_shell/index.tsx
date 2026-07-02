import { createFileRoute } from "@tanstack/react-router"

import { NewChatScreen } from "../../features/new-chat/NewChatScreen"

interface NewChatSearch {
  workspace?: string
}

export const Route = createFileRoute("/_shell/")({
  validateSearch: (search: Record<string, unknown>): NewChatSearch => ({
    workspace: typeof search.workspace === "string" ? search.workspace : undefined
  }),
  component: NewChatRoute
})

function NewChatRoute() {
  const { workspace } = Route.useSearch()
  // Remount when the preferred workspace changes so the local selection reset
  // mirrors the Swift `.task(id: preferredWorkspaceId)` behavior.
  return <NewChatScreen key={workspace ?? "none"} preferredWorkspaceId={workspace} />
}
