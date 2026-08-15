import type * as acp from "@agentclientprotocol/sdk"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
/// pi-acp includes Pi's human-readable startup prelude in `_meta` and then
/// republishes that exact text as an agent message. It is useful in terminals,
/// but in a native transcript it looks like the assistant spoke before the
/// user. Keep the exact value so only that adapter-owned message is suppressed.
export const extractPiStartupInfo = (response: unknown): string | undefined => {
  if (typeof response !== "object" || response === null) return undefined
  const meta = (response as { readonly _meta?: unknown })._meta
  if (typeof meta !== "object" || meta === null) return undefined
  const piAcp = (meta as { readonly piAcp?: unknown }).piAcp
  if (typeof piAcp !== "object" || piAcp === null) return undefined
  const startupInfo = (piAcp as { readonly startupInfo?: unknown }).startupInfo
  return typeof startupInfo === "string" && startupInfo.length > 0 ? startupInfo : undefined
}

export const isPiStartupInfoNotification = (
  notification: acp.SessionNotification,
  startupInfo: string
): boolean => {
  const update = notification.update
  return (
    update.sessionUpdate === "agent_message_chunk" &&
    update.content.type === "text" &&
    update.content.text === startupInfo
  )
}

export const piAssistantErrorFromSessionJsonl = (contents: string): string | undefined => {
  const lines = contents.split("\n")
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index]?.trim()
    if (!line) continue
    try {
      const entry = JSON.parse(line) as {
        readonly type?: unknown
        readonly message?: {
          readonly role?: unknown
          readonly stopReason?: unknown
          readonly errorMessage?: unknown
        }
      }
      if (entry.type !== "message") continue
      if (entry.message?.role !== "assistant" || entry.message.stopReason !== "error") {
        return undefined
      }
      if (typeof entry.message.errorMessage !== "string") return undefined
      return humanReadablePiError(entry.message.errorMessage)
    } catch {
      return undefined
    }
  }
  return undefined
}

const humanReadablePiError = (message: string): string => {
  const jsonStart = message.indexOf("{")
  if (jsonStart >= 0) {
    try {
      const parsed = JSON.parse(message.slice(jsonStart)) as {
        readonly error?: { readonly message?: unknown }
      }
      if (typeof parsed.error?.message === "string" && parsed.error.message.trim().length > 0) {
        return parsed.error.message.trim()
      }
    } catch {
      // Keep the provider's original text when it is not JSON-shaped.
    }
  }
  return message.trim()
}

export const readPiSessionError = async (
  sessionId: string,
  homeDirectory: string
): Promise<string | undefined> => {
  try {
    const mapContents = await readFile(
      join(homeDirectory, ".pi", "pi-acp", "session-map.json"),
      "utf8"
    )
    const map = JSON.parse(mapContents) as {
      readonly sessions?: Record<string, { readonly sessionFile?: unknown }>
    }
    const sessionFile = map.sessions?.[sessionId]?.sessionFile
    if (typeof sessionFile !== "string" || sessionFile.length === 0) return undefined
    return piAssistantErrorFromSessionJsonl(await readFile(sessionFile, "utf8"))
  } catch {
    // Recovery is best-effort until pi-acp forwards message_end errors itself.
    return undefined
  }
}
/* v8 ignore stop */
