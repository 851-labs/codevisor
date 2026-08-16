import {
  attachTarget,
  discardTargetState,
  invalidateTargetSession,
  type BrowserRuntime
} from "./browser-cdp-engine.js"

export const installSessionRecovery = (
  runtime: BrowserRuntime,
  recoverUnknownSessions: boolean
): void => {
  const recoveries = new Map<string, Promise<string>>()
  runtime.eventDisposers.push(
    runtime.connection.setSessionRecoveryHandler(async ({ cause, sessionId }) => {
      if (!recoverUnknownSessions || cause.message !== "Unknown Codevisor tab session") {
        return undefined
      }
      const targetId = invalidateTargetSession(runtime, sessionId)
      if (targetId === undefined) return undefined
      const existing = recoveries.get(targetId)
      if (existing !== undefined) return await existing
      const recovery = attachTarget(runtime, targetId).finally(() => {
        recoveries.delete(targetId)
      })
      recoveries.set(targetId, recovery)
      return await recovery
    })
  )
}

export const handleTargetLifecycleEvent = (
  runtime: BrowserRuntime,
  method: string,
  params: Readonly<Record<string, unknown>>
): void => {
  if (method === "Target.detachedFromTarget" && typeof params.sessionId === "string") {
    invalidateTargetSession(runtime, params.sessionId)
    return
  }
  if (method !== "Target.targetDestroyed" || typeof params.targetId !== "string") return
  discardTargetState(runtime, params.targetId)
  runtime.tabOrder = runtime.tabOrder.filter((targetId) => targetId !== params.targetId)
}
