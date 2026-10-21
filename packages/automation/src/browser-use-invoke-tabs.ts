import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import {
  discardTargetState,
  jsonResult,
  numberArgument,
  pageTargets,
  stringArgument,
  waitForCreatedTarget
} from "./browser-cdp-engine.js"
import type { BrowserRuntime, TargetInfo } from "./browser-cdp-engine.js"
import { waitForTargetsClosed } from "./browser-runtime-lifecycle.js"
import type { BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { isStringArray } from "./unknown-values.js"

export interface BrowserTabInvocation {
  readonly active: BrowserRuntime
  readonly args: Readonly<Record<string, unknown>>
  readonly sessionKey: string
  readonly state: BrowserToolSessionState
  readonly toolName: string
  readonly groupCreated: () => Promise<void>
  readonly releaseInput: () => void
}

export type BrowserTabTool = (tab: BrowserTabInvocation) => Promise<CallToolResult>

export const blankPageUrl = "about:blank"

export const tabTool = (toolName: string): BrowserTabTool | undefined => {
  switch (toolName) {
    case "finalizeTabs":
      return finalizeTabs
    case "markTab":
      return markTab
    case "tabs":
      return tabs
    default:
      return undefined
  }
}

export const selectCreatedTarget = (
  state: BrowserToolSessionState,
  sessionKey: string,
  targetId: string
): void => {
  state.selectedTargets.set(sessionKey, targetId)
  controlledTargets(state, sessionKey).set(targetId, "created")
}

type TabOrigin = "created" | "claimed" | "kept"

interface FinalizedTabs {
  readonly kept: string[]
  readonly closed: string[]
  readonly released: string[]
  readonly failed: string[]
}

const finalizeTabs = (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  if (tab.args.native === true) return finalizeNativeTabs(tab)
  return finalizeSelectedTab(tab)
}

const finalizeNativeTabs = async (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  const { active, sessionKey, state } = tab
  const keepIds = keptTargetIds(tab)
  const finalized: FinalizedTabs = { kept: [], closed: [], released: [], failed: [] }
  for (const [targetId, origin] of state.sessionTargets.get(sessionKey) ?? new Map()) {
    if (closesOnFinalize(origin, targetId, keepIds)) {
      try {
        await closeTarget(active, targetId)
        finalized.closed.push(targetId)
      } catch {
        finalized.failed.push(targetId)
      }
    } else {
      const tabSessionId = active.sessions.get(targetId)
      if (tabSessionId !== undefined)
        await detachTarget(active, tabSessionId).catch(() => undefined)
      recordUnclosed(finalized, targetId, origin)
    }
    discardTargetState(active, targetId)
  }
  await waitForTargetsClosed(active, finalized.closed)

  rememberKeptTargets(tab, finalized.kept)
  state.sessionDispositions.delete(sessionKey)
  forgetSelection(tab)
  const { kept, closed, released, failed } = finalized
  return jsonResult({
    finalized: true,
    kept,
    closed,
    released,
    ...(failed.length === 0 ? {} : { failed })
  })
}

const keptTargetIds = ({ args, sessionKey, state }: BrowserTabInvocation): Set<string> => {
  const requestedKeepIds = args.keepIds === undefined ? [] : args.keepIds
  if (!isStringArray(requestedKeepIds)) throw new Error("keepIds must be an array of tab ids")
  return new Set([
    ...requestedKeepIds,
    ...(state.sessionDispositions.get(sessionKey)?.keys() ?? [])
  ])
}

const closesOnFinalize = (origin: TabOrigin, targetId: string, keepIds: Set<string>): boolean =>
  origin === "created" && !keepIds.has(targetId)

const recordUnclosed = (finalized: FinalizedTabs, targetId: string, origin: TabOrigin): void => {
  if (origin === "claimed") finalized.released.push(targetId)
  else finalized.kept.push(targetId)
}

const rememberKeptTargets = ({ sessionKey, state }: BrowserTabInvocation, kept: string[]): void => {
  if (kept.length === 0) state.sessionTargets.delete(sessionKey)
  else state.sessionTargets.set(sessionKey, new Map(kept.map((id) => [id, "kept"])))
}

const finalizeSelectedTab = async (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  const { active, args, sessionKey, state } = tab
  const targetId = state.selectedTargets.get(sessionKey)
  if (targetId === undefined) return jsonResult({ finalized: true, tabsClosed: false })

  const tabSessionId = active.sessions.get(targetId)
  if (args.close === true) await closeTarget(active, targetId)
  else if (tabSessionId !== undefined) await detachTarget(active, tabSessionId)
  forgetTarget(tab, targetId)
  forgetSelection(tab)
  return jsonResult({ finalized: true, tabsClosed: args.close === true })
}

const markTab = async ({ args, sessionKey, state }: BrowserTabInvocation) => {
  const status = stringArgument(args, "status")
  if (!isTabDisposition(status)) throw new Error("status must be deliverable or handoff")
  const targetId = typeof args.id === "string" ? args.id : state.selectedTargets.get(sessionKey)
  if (targetId === undefined) throw new Error("There is no selected tab to mark")

  const dispositions = state.sessionDispositions.get(sessionKey) ?? new Map()
  dispositions.set(targetId, status)
  state.sessionDispositions.set(sessionKey, dispositions)
  return jsonResult({ id: targetId, status })
}

const isTabDisposition = (status: string): status is "deliverable" | "handoff" =>
  status === "deliverable" || status === "handoff"

const tabs = (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  if (tab.args.action === "new") return openTab(tab)
  return changeTabs(tab)
}

const openTab = async (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  const { active, args, sessionKey, state } = tab
  const url = typeof args.url === "string" ? args.url : blankPageUrl
  const before = new Set((await pageTargets(active)).map((target) => target.targetId))
  const created = await active.connection
    .send<{ targetId: string }>("Target.createTarget", { url })
    .catch((cause: unknown) => closeStrayTabs(tab, before, cause))
  selectCreatedTarget(state, sessionKey, created.targetId)
  const targets = await waitForCreatedTarget(active, created.targetId, url)
  await tab.groupCreated()
  return listTabs(tab, targets)
}

const closeStrayTabs = async (
  { active, state }: BrowserTabInvocation,
  before: ReadonlySet<string>,
  cause: unknown
): Promise<never> => {
  const owned = new Set([...state.sessionTargets.values()].flatMap((map) => [...map.keys()]))
  const after = await pageTargets(active).catch(() => [])
  for (const target of after) {
    if (knownTab(target, before, owned)) continue
    await closeTarget(active, target.targetId).catch(() => undefined)
  }
  throw cause
}

const knownTab = (target: TargetInfo, before: ReadonlySet<string>, owned: ReadonlySet<string>) =>
  before.has(target.targetId) || owned.has(target.targetId)

const changeTabs = async (tab: BrowserTabInvocation): Promise<CallToolResult> => {
  const { active, args, sessionKey, state } = tab
  const action = stringArgument(args, "action")
  const targets = await pageTargets(active)
  switch (action) {
    case "select":
      selectTab(tab, targets)
      break
    case "close": {
      const selectedId = state.selectedTargets.get(sessionKey)
      const target = tabToClose(args, targets, selectedId)
      await closeTarget(active, target.targetId)
      forgetClosedTab(tab, target.targetId, selectedId)
      break
    }
    case "list":
      break
    default:
      throw new Error("tabs.action must be list, new, close, or select")
  }
  return listTabs(tab, targets)
}

const selectTab = ({ args, sessionKey, state }: BrowserTabInvocation, targets: TargetInfo[]) => {
  const target = requestedTab(args, targets)
  if (observedTabChanged(args, target)) {
    throw new Error("The observed user tab changed. List user tabs again before claiming it.")
  }

  state.selectedTargets.set(sessionKey, target.targetId)
  const controlled = controlledTargets(state, sessionKey)
  if (!controlled.has(target.targetId)) controlled.set(target.targetId, "claimed")
}

const requestedTab = (args: Readonly<Record<string, unknown>>, targets: TargetInfo[]) => {
  if (typeof args.id === "string") return tabWithId(targets, args.id)

  const index = numberArgument(args, "index")
  const target = targets[index]
  if (target === undefined) throw new Error(`No browser tab at index ${index}`)
  return target
}

const tabWithId = (targets: TargetInfo[], id: string): TargetInfo => {
  const target = findTab(targets, id)
  if (target === undefined) throw new Error(`No browser tab with id ${id}`)
  return target
}

const observedTabChanged = (args: Readonly<Record<string, unknown>>, target: TargetInfo) =>
  (typeof args.title === "string" && args.title !== target.title) ||
  (typeof args.url === "string" && args.url !== target.url)

const tabToClose = (
  args: Readonly<Record<string, unknown>>,
  targets: TargetInfo[],
  selectedId: string | undefined
): TargetInfo => {
  const target = closeCandidate(args, targets, selectedId)
  if (target === undefined) throw new Error("There is no browser tab to close")
  return target
}

const closeCandidate = (
  args: Readonly<Record<string, unknown>>,
  targets: TargetInfo[],
  selectedId: string | undefined
): TargetInfo | undefined => {
  if (typeof args.id === "string") return findTab(targets, args.id)
  if (typeof args.index === "number") return targets[args.index]
  return findTab(targets, selectedId) ?? targets[0]
}

const findTab = (targets: TargetInfo[], id: string | undefined): TargetInfo | undefined =>
  targets.find((candidate) => candidate.targetId === id)

const forgetClosedTab = (
  tab: BrowserTabInvocation,
  targetId: string,
  selectedId: string | undefined
): void => {
  if (selectedId === targetId) tab.state.selectedTargets.delete(tab.sessionKey)
  forgetTarget(tab, targetId)
}

const listTabs = ({ args, sessionKey, state }: BrowserTabInvocation, targets: TargetInfo[]) => {
  const selectedId = state.selectedTargets.get(sessionKey)
  const controlledTabs = state.sessionTargets.get(sessionKey)
  return jsonResult({
    tabs: scopedTabs(args, targets, controlledTabs).map((target, index) => ({
      id: target.targetId,
      index,
      selected: target.targetId === selectedId,
      ...(target.groupId === undefined ? {} : { groupId: target.groupId }),
      ...(controlledTabs?.has(target.targetId) === true
        ? { origin: controlledTabs.get(target.targetId) }
        : {}),
      title: target.title,
      url: target.url
    }))
  })
}

const scopedTabs = (
  args: Readonly<Record<string, unknown>>,
  targets: TargetInfo[],
  controlledTabs: ReadonlyMap<string, TabOrigin> | undefined
): TargetInfo[] => {
  if (args.scope !== "session") return targets
  return targets.filter((target) => controlledTabs?.has(target.targetId) === true)
}

const closeTarget = (active: BrowserRuntime, targetId: string) =>
  active.connection.send("Target.closeTarget", { targetId })

const detachTarget = (active: BrowserRuntime, sessionId: string) =>
  active.connection.send("Target.detachFromTarget", { sessionId })

const forgetTarget = ({ active, sessionKey, state }: BrowserTabInvocation, targetId: string) => {
  discardTargetState(active, targetId)
  state.sessionTargets.get(sessionKey)?.delete(targetId)
}

const forgetSelection = ({ releaseInput, sessionKey, state }: BrowserTabInvocation): void => {
  state.selectedTargets.delete(sessionKey)
  releaseInput()
}

const controlledTargets = (state: BrowserToolSessionState, sessionKey: string) => {
  const controlled = state.sessionTargets.get(sessionKey) ?? new Map<string, TabOrigin>()
  state.sessionTargets.set(sessionKey, controlled)
  return controlled
}
