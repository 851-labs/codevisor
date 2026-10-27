import type { PromptAttribution } from "@codevisor/api"

import { HttpFailure, type CodevisorServerServices } from "../server-context.js"

export const verifiedAttribution = async (
  services: CodevisorServerServices,
  sessionId: string,
  requested: PromptAttribution | undefined
): Promise<PromptAttribution | undefined> => {
  if (requested === undefined) return undefined

  const view = await services.mcp?.appView(requested.viewId)
  if (view === undefined || view.sessionId.toLowerCase() !== sessionId.toLowerCase()) {
    throw new HttpFailure(400, "That app view doesn't belong to this chat")
  }
  return { kind: "app", viewId: view.viewId, plugin: view.serverName }
}
