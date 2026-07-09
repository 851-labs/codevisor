import { createFileRoute } from "@tanstack/react-router"

import { SessionScreen } from "../../features/session/SessionScreen"

export const Route = createFileRoute("/_shell/session/$sessionId")({
  component: SessionRoute
})

function SessionRoute() {
  const { sessionId } = Route.useParams()
  return <SessionScreen key={sessionId} sessionId={sessionId} />
}
