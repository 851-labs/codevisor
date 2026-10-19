import type { IncomingMessage, ServerResponse } from "node:http"

import { TerminalCreateRequest, type Workspace } from "@codevisor/api"

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
    const isArchivedWorkspace = (workspace: Workspace): boolean =>
      workspace.isArchived &&
      (workspace.id === pane?.workspaceId || workspace.id === session?.workspaceId)
    if (workspaces.some(isArchivedWorkspace)) {
      throw new HttpFailure(409, "Restore the workspace before starting a terminal")
    }
    const terminal = await run(services.terminal.createTerminal(payload))
    const archivedNow = (await run(services.db.listWorkspaces)).some(isArchivedWorkspace)
    if (archivedNow) {
      await run(services.terminal.closeTerminal(terminal.terminalId))
      throw new HttpFailure(409, "Workspace was archived while starting the terminal")
    }
    writeJson(response, 201, terminal)
    return true
  }

  const terminalSessionId = matchRoute(url.pathname, "/v1/terminals/session/:sessionId")
  if (terminalSessionId !== undefined && request.method === "DELETE") {
    const closed = await run(services.terminal.closeTerminalForSession(terminalSessionId))
    writeJson(response, closed ? 200 : 404, { closed })
    return true
  }

  const screenTerminalId = matchRoute(url.pathname, "/v1/terminals/:id/screen")
  if (screenTerminalId !== undefined && request.method === "GET") {
    const format = url.searchParams.get("format") ?? "text"
    if (format !== "text" && format !== "vt") {
      throw new HttpFailure(400, "format must be text or vt")
    }
    const screen = await run(services.terminal.readScreen(screenTerminalId, format)).catch(() => {
      throw new HttpFailure(404, `Terminal not found: ${screenTerminalId}`)
    })
    writeJson(response, 200, { format, screen })
    return true
  }

  return false
}
