import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import type { AutomationProviderContext } from "./automation-provider.js"
import {
  currentPage,
  discardTargetState,
  jsonResult,
  numberArgument,
  pageTargets,
  stringArgument,
  waitForCreatedTarget
} from "./browser-cdp-engine.js"
import type { BrowserRuntime, TargetInfo } from "./browser-cdp-engine.js"
import type { BrowserBackend } from "./browser-use-provider.js"
import { invokeNavigationTools } from "./browser-use-invoke-navigation.js"
import { invokePlaywrightTools } from "./browser-use-invoke-playwright.js"
import { invokePageTools } from "./browser-use-invoke-page.js"
import { invokeInteractionTools } from "./browser-use-invoke-interaction.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

export type {
  BrowserAssetInventory,
  BrowserToolInvocation,
  BrowserToolSessionState
} from "./browser-use-invoke-types.js"

/// Tool families tried in order for every page-scoped tool call; the first
/// handler that owns the tool name answers.
const toolHandlers = [
  invokeNavigationTools,
  invokePlaywrightTools,
  invokePageTools,
  invokeInteractionTools
]

export const runtimeKey = (context: AutomationProviderContext, backend: BrowserBackend): string =>
  backend === "managed" ? `managed:${context.projectId ?? "global"}` : "extension"

export const makeBrowserToolInvoker = (state: BrowserToolSessionState) => {
  const { selectedTargets, sessionBackends, sessionDispositions, sessionTargets } = state
  return async (
    context: AutomationProviderContext,
    active: BrowserRuntime,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ): Promise<CallToolResult> => {
    const backend = sessionBackends.get(context.sessionId) ?? "managed"
    const sessionKey = `${runtimeKey(context, backend)}:${context.sessionId}`
    if (toolName === "finalizeTabs") {
      if (args.native === true) {
        if (
          args.keepIds !== undefined &&
          (!Array.isArray(args.keepIds) ||
            !args.keepIds.every((value) => typeof value === "string"))
        ) {
          throw new Error("keepIds must be an array of tab ids")
        }
        const keepIds = new Set([
          ...((args.keepIds as string[] | undefined) ?? []),
          ...(sessionDispositions.get(sessionKey)?.keys() ?? [])
        ])
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        for (const [targetId, origin] of controlled) {
          const tabSessionId = active.sessions.get(targetId)
          if (origin === "created" && !keepIds.has(targetId)) {
            await active.connection.send("Target.closeTarget", { targetId }).catch(() => undefined)
          } else if (tabSessionId !== undefined) {
            await active.connection
              .send("Target.detachFromTarget", { sessionId: tabSessionId })
              .catch(() => undefined)
          }
          discardTargetState(active, targetId)
        }
        sessionTargets.delete(sessionKey)
        sessionDispositions.delete(sessionKey)
        selectedTargets.delete(sessionKey)
        return jsonResult({ finalized: true, kept: [...keepIds] })
      }
      const targetId = selectedTargets.get(sessionKey)
      if (targetId === undefined) return jsonResult({ finalized: true, tabsClosed: false })
      const tabSessionId = active.sessions.get(targetId)
      if (args.close === true) {
        await active.connection.send("Target.closeTarget", { targetId })
      } else if (tabSessionId !== undefined) {
        await active.connection.send("Target.detachFromTarget", { sessionId: tabSessionId })
      }
      discardTargetState(active, targetId)
      sessionTargets.get(sessionKey)?.delete(targetId)
      selectedTargets.delete(sessionKey)
      return jsonResult({ finalized: true, tabsClosed: args.close === true })
    }
    if (toolName === "markTab") {
      const status = stringArgument(args, "status")
      if (status !== "deliverable" && status !== "handoff") {
        throw new Error("status must be deliverable or handoff")
      }
      const targetId = typeof args.id === "string" ? args.id : selectedTargets.get(sessionKey)
      if (targetId === undefined) throw new Error("There is no selected tab to mark")
      const dispositions = sessionDispositions.get(sessionKey) ?? new Map()
      dispositions.set(targetId, status)
      sessionDispositions.set(sessionKey, dispositions)
      return jsonResult({ id: targetId, status })
    }
    if (toolName === "tabs") {
      const action = stringArgument(args, "action")
      let targets: TargetInfo[] | undefined
      if (action === "new") {
        const url = typeof args.url === "string" ? args.url : "about:blank"
        const created = await active.connection.send<{ targetId: string }>("Target.createTarget", {
          url
        })
        selectedTargets.set(sessionKey, created.targetId)
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        controlled.set(created.targetId, "created")
        sessionTargets.set(sessionKey, controlled)
        targets = await waitForCreatedTarget(active, created.targetId, url)
      } else {
        targets = await pageTargets(active)
        if (action === "select") {
          const id = typeof args.id === "string" ? args.id : undefined
          const index = id === undefined ? numberArgument(args, "index") : undefined
          const target =
            id === undefined
              ? targets[index!]
              : targets.find((candidate) => candidate.targetId === id)
          if (target === undefined) {
            throw new Error(
              id === undefined ? `No browser tab at index ${index}` : `No browser tab with id ${id}`
            )
          }
          selectedTargets.set(sessionKey, target.targetId)
          const controlled = sessionTargets.get(sessionKey) ?? new Map()
          if (!controlled.has(target.targetId)) controlled.set(target.targetId, "claimed")
          sessionTargets.set(sessionKey, controlled)
        } else if (action === "close") {
          const selectedId = selectedTargets.get(sessionKey)
          const id = typeof args.id === "string" ? args.id : undefined
          const index = typeof args.index === "number" ? args.index : undefined
          const target =
            id !== undefined
              ? targets.find((candidate) => candidate.targetId === id)
              : index === undefined
                ? (targets.find((candidate) => candidate.targetId === selectedId) ?? targets[0])
                : targets[index]
          if (target === undefined) throw new Error("There is no browser tab to close")
          await active.connection.send("Target.closeTarget", { targetId: target.targetId })
          if (selectedId === target.targetId) selectedTargets.delete(sessionKey)
          discardTargetState(active, target.targetId)
          sessionTargets.get(sessionKey)?.delete(target.targetId)
        } else if (action !== "list")
          throw new Error("tabs.action must be list, new, close, or select")
      }
      targets ??= await pageTargets(active)
      const selectedId = selectedTargets.get(sessionKey)
      return jsonResult({
        tabs: targets.map((target, index) => ({
          id: target.targetId,
          index,
          selected: target.targetId === selectedId,
          title: target.title,
          url: target.url
        }))
      })
    }
    if (toolName === "user.history") {
      if (backend !== "extension") {
        throw new Error("Browser history is only available with the user Chrome backend")
      }
      const toTimestamp = (value: unknown): number | undefined => {
        if (typeof value === "number" && Number.isFinite(value)) return value
        if (typeof value !== "string") return undefined
        const parsed = Date.parse(value)
        if (Number.isNaN(parsed)) throw new Error(`Invalid history date: ${value}`)
        return parsed
      }
      const raw = await active.connection.send<{
        entries?: Array<{ url?: string; title?: string; lastVisitTime?: number }>
      }>("Codevisor.getHistory", {
        text:
          Array.isArray(args.queries) && args.queries.every((query) => typeof query === "string")
            ? args.queries.join(" ")
            : "",
        ...(toTimestamp(args.from) === undefined ? {} : { startTime: toTimestamp(args.from) }),
        ...(toTimestamp(args.to) === undefined ? {} : { endTime: toTimestamp(args.to) }),
        maxResults: typeof args.limit === "number" ? Math.max(1, Math.min(1_000, args.limit)) : 100
      })
      return jsonResult({
        entries: (raw.entries ?? [])
          .filter((entry): entry is typeof entry & { url: string } => typeof entry.url === "string")
          .map((entry) => ({
            url: entry.url,
            dateVisited: new Date(entry.lastVisitTime ?? 0).toISOString(),
            ...(typeof entry.title === "string" ? { title: entry.title } : {})
          }))
      })
    }

    const page = await currentPage(active, selectedTargets, sessionKey)
    const invocation: BrowserToolInvocation = { active, args, backend, page, toolName }
    for (const invoke of toolHandlers) {
      const result = await invoke(invocation, state)
      if (result !== undefined) return result
    }
    throw new Error(`Unknown Browser Use tool: ${toolName}`)
  }
}
