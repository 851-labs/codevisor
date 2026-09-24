import type { IncomingMessage, ServerResponse } from "node:http"

import { TerminalCreateRequest } from "@codevisor/api"

import {
  matchRoute,
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeTerminals = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "POST" && url.pathname === "/v1/terminals") {
    const payload = await readSchema(request, TerminalCreateRequest)
    const key = payload.sessionId.toLowerCase()
    const sessions = await run(services.db.listSessions)
    const session = sessions.find((candidate) =>
      [candidate.id, candidate.agentSessionId].some(
        (id) =>
          id !== undefined && (key === id.toLowerCase() || key.startsWith(`${id.toLowerCase()}:`))
      )
    )
    const panes = await run(services.db.listWorkspacePanes)
    const pane = panes.find(
      (candidate) =>
        candidate.paneType === "terminal" && candidate.resourceId?.toLowerCase() === key
    )
    const workspaces = await run(services.db.listWorkspaces)
    // The workspace carries the archive, and the chat's own workspace is
    // already covered here, so there is no separate per-chat state to check.
    if (
      workspaces.some(
        (workspace) =>
          workspace.isArchived &&
          (workspace.id === pane?.workspaceId || workspace.id === session?.workspaceId)
      )
    ) {
      throw new HttpFailure(409, "Restore the workspace before starting a terminal")
    }
    const terminal = await run(services.terminal.createTerminal(payload))
    // A concurrent archive may have happened while the PTY was spawning.
    const archivedNow = (await run(services.db.listWorkspaces)).some(
      (workspace) =>
        workspace.isArchived &&
        (workspace.id === pane?.workspaceId || workspace.id === session?.workspaceId)
    )
    if (archivedNow) {
      await run(services.terminal.closeTerminal(terminal.terminalId))
      throw new HttpFailure(409, "Workspace was archived while starting the terminal")
    }
    writeJson(response, 201, terminal)
    return true
  }

  // Kills the session's live shell so the next createTerminal starts fresh
  // (used by the clients' "Restart Terminal" action).
  const terminalSessionId = matchRoute(url.pathname, "/v1/terminals/session/:sessionId")
  if (terminalSessionId !== undefined && request.method === "DELETE") {
    const closed = await run(services.terminal.closeTerminalForSession(terminalSessionId))
    writeJson(response, closed ? 200 : 404, { closed })
    return true
  }

  return false
}
