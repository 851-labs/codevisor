import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import type { AutomationProviderContext } from "./automation-provider.js"
import {
  attachTarget,
  booleanArgument,
  currentPage,
  jsonResult,
  pageTargets,
  stringArgument
} from "./browser-cdp-engine.js"
import type { BrowserRuntime, PageHandle, TargetInfo } from "./browser-cdp-engine.js"
import { makeBrowserCursorRegistry, type BrowserCursorRegistry } from "./browser-cursor.js"
import { initialPointerState, type PointerState } from "./browser-input.js"
import { invokeInteractionTools } from "./browser-use-invoke-interaction.js"
import { invokeMouseTools } from "./browser-use-invoke-mouse.js"
import { invokeNavigationTools } from "./browser-use-invoke-navigation.js"
import { invokePageTools } from "./browser-use-invoke-page.js"
import { invokePlaywrightTools } from "./browser-use-invoke-playwright.js"
import {
  blankPageUrl,
  selectCreatedTarget,
  tabTool,
  type BrowserTabInvocation
} from "./browser-use-invoke-tabs.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import type { BrowserBackend } from "./browser-use-provider.js"
import { isStringArray } from "./unknown-values.js"

export type {
  BrowserAssetInventory,
  BrowserToolInvocation,
  BrowserToolSessionState
} from "./browser-use-invoke-types.js"

interface BrowserInvokerMemory {
  readonly cursors: BrowserCursorRegistry
  readonly names: Map<string, string>
  readonly groups: Map<string, number>
  readonly pointers: Map<string, PointerState>
}

interface BrowserSessionInvocation extends BrowserTabInvocation {
  readonly backend: BrowserBackend
  readonly memory: BrowserInvokerMemory
}

type BrowserSessionTool = (session: BrowserSessionInvocation) => Promise<CallToolResult>

const toolHandlers = [
  invokeNavigationTools,
  invokePlaywrightTools,
  invokePageTools,
  invokeInteractionTools,
  invokeMouseTools
]

const TAB_GROUP_COLORS: ReadonlySet<string> = new Set([
  "grey",
  "blue",
  "red",
  "yellow",
  "green",
  "pink",
  "purple",
  "cyan",
  "orange"
])

const maxSessionNameLength = 100
const sessionGroupColor = "blue"
const tabIdPattern = /^\d+$/
const minHistoryResults = 1
const maxHistoryResults = 1_000
const defaultHistoryResults = 100

export const runtimeKey = (context: AutomationProviderContext, backend: BrowserBackend): string => {
  if (backend === "builtin") return `builtin:${context.sessionId}`
  if (backend === "managed") return `managed:${context.projectId ?? "global"}`
  return "extension"
}

export const makeBrowserToolInvoker = (state: BrowserToolSessionState) => {
  const memory: BrowserInvokerMemory = {
    cursors: makeBrowserCursorRegistry(),
    names: new Map(),
    groups: new Map(),
    pointers: new Map()
  }
  return (
    context: AutomationProviderContext,
    active: BrowserRuntime,
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    backendOverride?: BrowserBackend
  ): Promise<CallToolResult> => {
    try {
      const backend = backendOverride ?? state.sessionBackends.get(context.sessionId) ?? "managed"
      const sessionKey = `${runtimeKey(context, backend)}:${context.sessionId}`
      const session = sessionInvocation({
        active,
        args,
        backend,
        memory,
        sessionKey,
        state,
        toolName
      })
      const tool = sessionTool(toolName)
      if (tool !== undefined) return tool(session)

      return invokeOnPage(session)
    } catch (cause) {
      return Promise.reject(cause)
    }
  }
}

const sessionInvocation = (
  call: Omit<BrowserSessionInvocation, "groupCreated" | "releaseInput">
): BrowserSessionInvocation => {
  const { memory, sessionKey } = call
  const session: BrowserSessionInvocation = {
    ...call,
    groupCreated: () => groupCreatedTabs(session),
    releaseInput: () => {
      memory.cursors.release(sessionKey)
      memory.pointers.delete(sessionKey)
    }
  }
  return session
}

const sessionTool = (toolName: string): BrowserSessionTool | undefined => {
  switch (toolName) {
    case "nameSession":
      return nameSession
    case "tab_groups":
      return tabGroups
    case "user.history":
      return userHistory
    default:
      return tabTool(toolName)
  }
}

const invokeOnPage = async (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  const { active, args, sessionKey, state } = session
  let page: PageHandle
  if (typeof args.tabId === "string") {
    requireOwnedTab(session, args.tabId)
    const target = openTabWithId(await pageTargets(active), args.tabId)
    page = {
      target,
      sessionId: await attachTarget(active, target.targetId),
      snapshotKey: `${sessionKey}:${target.targetId}`
    }
  } else {
    if (needsFirstTab(session)) {
      const created = await createBlankTab(active)
      selectCreatedTarget(state, sessionKey, created.targetId)
    }
    page = await currentPage(active, state.selectedTargets, sessionKey)
  }

  const invocation = pageInvocation(session, page)
  for (const invoke of toolHandlers) {
    const result = await invoke(invocation, state)
    if (result !== undefined) return result
  }
  throw new Error(`Unknown Browser Use tool: ${session.toolName}`)
}

const requireOwnedTab = ({ sessionKey, state }: BrowserSessionInvocation, tabId: string): void => {
  if (!state.sessionTargets.get(sessionKey)?.has(tabId))
    throw new Error("This session does not own that tab. Claim an observed user tab first.")
}

const openTabWithId = (targets: TargetInfo[], tabId: string): TargetInfo => {
  const target = targets.find((tab) => tab.targetId === tabId)
  if (!target) throw new Error("The requested browser tab was closed; it will not be replaced.")
  return target
}

const needsFirstTab = ({ sessionKey, state, toolName }: BrowserSessionInvocation): boolean =>
  !state.selectedTargets.has(sessionKey) && toolName === "navigate"

const createBlankTab = (active: BrowserRuntime) =>
  active.connection.send<{ targetId: string }>("Target.createTarget", { url: blankPageUrl })

const pageInvocation = (
  { active, args, backend, memory, sessionKey, toolName }: BrowserSessionInvocation,
  page: PageHandle
): BrowserToolInvocation => ({
  active,
  args,
  backend,
  cursor: memory.cursors.cursorFor(active, page, sessionKey),
  page,
  pointer: pointerFor(memory.pointers, `${sessionKey}:${page.target.targetId}`),
  toolName
})

const pointerFor = (pointers: Map<string, PointerState>, pointerKey: string): PointerState => {
  const existing = pointers.get(pointerKey)
  if (existing !== undefined) return existing

  const created = initialPointerState()
  pointers.set(pointerKey, created)
  return created
}

const nameSession = async (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  const name = stringArgument(session.args, "name").trim()
  if (invalidSessionName(name)) throw new Error("Session name must contain 1–100 characters")
  session.memory.names.set(session.sessionKey, name)
  await session.groupCreated()
  return jsonResult({ name })
}

const invalidSessionName = (name: string): boolean => !name || name.length > maxSessionNameLength

const groupCreatedTabs = async (session: BrowserSessionInvocation): Promise<void> => {
  const { active, backend, memory, sessionKey, state } = session
  const name = memory.names.get(sessionKey)
  if (!name) return
  if (backend !== "extension") return
  const ids = createdTargetIds(state, sessionKey)
  if (!ids.length) return

  const listed = await listTabGroups(active)
  const existing = liveGroupId(listed.groups, memory.groups.get(sessionKey))
  if (existing === undefined) {
    const created = await createTabGroup(active, ids, name)
    memory.groups.set(sessionKey, created.group.id)
  } else {
    await active.connection.send("Codevisor.tabGroups.add", { groupId: existing, tabIds: ids })
    await active.connection.send("Codevisor.tabGroups.update", { groupId: existing, title: name })
  }
}

const createdTargetIds = (state: BrowserToolSessionState, sessionKey: string): string[] =>
  [...(state.sessionTargets.get(sessionKey) ?? [])]
    .filter(([, origin]) => origin === "created")
    .map(([id]) => id)

const listTabGroups = (active: BrowserRuntime) =>
  active.connection.send<{ groups: { id: number }[] }>("Codevisor.tabGroups.list", {})

const liveGroupId = (groups: { id: number }[], groupId: number | undefined) => {
  if (groupId === undefined) return undefined
  if (!groups.some((group) => group.id === groupId)) return undefined
  return groupId
}

const createTabGroup = (active: BrowserRuntime, tabIds: string[], title: string) =>
  active.connection.send<{ group: { id: number } }>("Codevisor.tabGroups.create", {
    tabIds,
    title,
    color: sessionGroupColor
  })

type TabGroupSend = (
  method: string,
  params: Readonly<Record<string, unknown>>
) => Promise<Readonly<Record<string, unknown>>>

const tabGroups = (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  if (session.args.action === "ensure") return ensureTabGroup(session)
  return changeTabGroups(session)
}

const changeTabGroups = async (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  requireExtensionBackend(session, "Tab groups are only available with the user Chrome backend")
  const { args } = session
  const action = stringArgument(args, "action")
  const send = tabGroupSender(session)
  switch (action) {
    case "list":
      return jsonResult(await send("list", {}))
    case "create":
      return jsonResult(await send("create", { tabIds: tabIds(args), ...appearance(args) }))
    case "add":
      return jsonResult(await send("add", { groupId: groupId(args), tabIds: tabIds(args) }))
    case "update":
      return jsonResult(await send("update", { groupId: groupId(args), ...appearance(args) }))
    case "ungroup":
      await send("ungroup", { tabIds: tabIds(args) })
      return jsonResult({ ungrouped: tabIds(args) })
    default:
      throw new Error("tab_groups.action must be list, create, ensure, add, update, or ungroup")
  }
}

const ensureTabGroup = async (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  requireExtensionBackend(session, "Tab groups are only available with the user Chrome backend")
  const { args } = session
  const send = tabGroupSender(session)
  const title = stringArgument(args, "title")
  const listed = (await send("list", {})) as {
    groups?: ReadonlyArray<{ id: number; title?: string; tabIds?: ReadonlyArray<string> }>
  }
  const ids = tabIds(args)
  const existing = (listed.groups ?? []).find((group) => group.title === title)
  if (existing === undefined) {
    return jsonResult({
      ...(await send("create", { tabIds: ids, ...appearance(args) })),
      created: true
    })
  }

  const missing = ids.filter((id) => !(existing.tabIds ?? []).includes(id))
  if (missing.length > 0) await send("add", { groupId: existing.id, tabIds: missing })
  const { title: _title, ...restyle } = appearance(args)
  return jsonResult({
    ...(await send("update", { groupId: existing.id, ...restyle })),
    created: false
  })
}

const tabGroupSender =
  ({ active }: BrowserSessionInvocation): TabGroupSend =>
  (method, params) =>
    active.connection.send(`Codevisor.tabGroups.${method}`, params)

const tabIds = (args: Readonly<Record<string, unknown>>): string[] => {
  const raw = args.tabIds
  if (!isTabIdList(raw)) throw new Error("tabIds must be a non-empty array of tab ids from tabs")
  return raw
}

const isTabIdList = (value: unknown): value is string[] =>
  Array.isArray(value) &&
  value.length > 0 &&
  value.every((id) => typeof id === "string" && tabIdPattern.test(id))

const groupId = (args: Readonly<Record<string, unknown>>): number => {
  const value = args.groupId
  if (!isGroupId(value)) throw new Error("groupId must be the id of a group returned by tab_groups")
  return value
}

const isGroupId = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value >= 0

const appearance = (args: Readonly<Record<string, unknown>>): Readonly<Record<string, unknown>> => {
  const properties: Record<string, unknown> = {}
  if (args.title !== undefined) properties.title = stringArgument(args, "title")
  if (args.color !== undefined) {
    if (!isTabGroupColor(args.color)) {
      throw new Error(`color must be one of ${[...TAB_GROUP_COLORS].join(", ")}`)
    }
    properties.color = args.color
  }
  if (args.collapsed !== undefined) properties.collapsed = booleanArgument(args, "collapsed")
  return properties
}

const isTabGroupColor = (value: unknown): value is string =>
  typeof value === "string" && TAB_GROUP_COLORS.has(value)

interface HistoryResponse {
  readonly entries?: Array<{ url?: string; title?: string; lastVisitTime?: number }>
}

const userHistory = async (session: BrowserSessionInvocation): Promise<CallToolResult> => {
  requireExtensionBackend(session, "Browser history is only available with the user Chrome backend")
  const raw = await session.active.connection.send<HistoryResponse>(
    "Codevisor.getHistory",
    historyQuery(session.args)
  )
  return jsonResult({ entries: visitedPages(raw) })
}

const historyQuery = (args: Readonly<Record<string, unknown>>) => ({
  text: isStringArray(args.queries) ? args.queries.join(" ") : "",
  ...(toTimestamp(args.from) === undefined ? {} : { startTime: toTimestamp(args.from) }),
  ...(toTimestamp(args.to) === undefined ? {} : { endTime: toTimestamp(args.to) }),
  maxResults: historyLimit(args.limit)
})

const historyLimit = (limit: unknown): number => {
  if (typeof limit !== "number") return defaultHistoryResults
  return Math.max(minHistoryResults, Math.min(maxHistoryResults, limit))
}

const toTimestamp = (value: unknown): number | undefined => {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value !== "string") return undefined
  const parsed = Date.parse(value)
  if (Number.isNaN(parsed)) throw new Error(`Invalid history date: ${value}`)
  return parsed
}

const visitedPages = (raw: HistoryResponse) =>
  (raw.entries ?? [])
    .filter((entry): entry is typeof entry & { url: string } => typeof entry.url === "string")
    .map((entry) => ({
      url: entry.url,
      dateVisited: new Date(entry.lastVisitTime ?? 0).toISOString(),
      ...(typeof entry.title === "string" ? { title: entry.title } : {})
    }))

const requireExtensionBackend = (session: BrowserSessionInvocation, message: string): void => {
  if (session.backend !== "extension") throw new Error(message)
}
