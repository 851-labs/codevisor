import { TerminalCreateRequest } from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  matchRoute,
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
    writeJson(
      response,
      201,
      await run(services.terminal.createTerminal(await readSchema(request, TerminalCreateRequest)))
    )
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
