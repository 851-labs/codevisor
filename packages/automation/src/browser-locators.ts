import { delay, evaluatedValue } from "./browser-cdp.js"
import { assertReadOnlyFunction } from "./browser-cdp-engine.js"
import type { BrowserRuntime, PageHandle, ResolvedElement } from "./browser-cdp-engine.js"
import { normalizeRef } from "./browser-snapshot.js"
import { locatorBackendNodeIds } from "./browser-locator-resolve.js"
export { locatorBackendNodeIds } from "./browser-locator-resolve.js"

const resolveBackendElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  backendNodeId: number,
  targetLabel: string,
  requireActionable: boolean
): Promise<ResolvedElement> => {
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error(`${targetLabel} is no longer attached`)
  try {
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration:
          "function(){ this.scrollIntoView({block:'center',inline:'center',behavior:'instant'}); }",
        returnByValue: true
      },
      page.sessionId
    )
    await delay(50)
    const state = evaluatedValue<{
      connected: boolean
      visible: boolean
      disabled: boolean
      hit: boolean
    }>(
      await runtime.connection.send(
        "Runtime.callFunctionOn",
        {
          objectId,
          functionDeclaration:
            "function(){const r=this.getBoundingClientRect();const s=getComputedStyle(this);const h=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return {connected:this.isConnected,visible:r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&s.pointerEvents!=='none',disabled:!!this.disabled||this.getAttribute('aria-disabled')==='true',hit:h===this||this.contains(h)};}",
          returnByValue: true
        },
        page.sessionId
      )
    )
    if (!state.connected) throw new Error(`${targetLabel} detached`)
    if (!state.visible) throw new Error(`${targetLabel} is not visible after scrolling`)
    if (requireActionable && state.disabled) throw new Error(`${targetLabel} is disabled`)
    if (requireActionable && !state.hit)
      throw new Error(`${targetLabel} is obscured at its action point`)
    const model = await runtime.connection.send<{
      model: { content: number[]; border: number[]; width: number; height: number }
    }>("DOM.getBoxModel", { backendNodeId }, page.sessionId)
    const quad = model.model.border.length >= 8 ? model.model.border : model.model.content
    const x = (quad[0]! + quad[2]! + quad[4]! + quad[6]!) / 4
    const y = (quad[1]! + quad[3]! + quad[5]! + quad[7]!) / 4
    return {
      backendNodeId,
      objectId,
      x,
      y,
      width: model.model.width,
      height: model.model.height
    }
  } catch (cause) {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
    throw cause
  }
}

export const resolveLocatorElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  requireActionable = true,
  timeoutMs = 30_000
): Promise<ResolvedElement> => {
  const deadline = Date.now() + Math.max(0, Math.min(30_000, timeoutMs))
  let lastError = "Playwright locator resolved to 0 elements"
  while (true) {
    const ids = await locatorBackendNodeIds(runtime, page, locator)
    if (ids.length > 1) {
      throw new Error(
        `Playwright strict mode violation: locator resolved to ${ids.length} elements`
      )
    }
    if (ids.length === 1) {
      try {
        return await resolveBackendElement(
          runtime,
          page,
          ids[0]!,
          "Playwright locator",
          requireActionable
        )
      } catch (cause) {
        lastError = cause instanceof Error ? cause.message : String(cause)
      }
    }
    if (Date.now() >= deadline) throw new Error(lastError)
    await delay(100)
  }
}

export const resolveElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  target: unknown,
  requireActionable = true
): Promise<ResolvedElement> => {
  const snapshot = runtime.snapshots.get(page.target.targetId)
  if (snapshot === undefined)
    throw new Error("No current Browser Use snapshot; call snapshot first")
  const ref = normalizeRef(target)
  const backendNodeId = snapshot.targets.get(ref)
  if (backendNodeId === undefined) {
    throw new Error(`Unknown or stale target ${ref}; call snapshot again and use a current ref`)
  }
  return resolveBackendElement(runtime, page, backendNodeId, `Target ${ref}`, requireActionable)
}

export const releaseElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<void> => {
  // Runtime commands are suspended while a JavaScript modal is open. The remote object is
  // reclaimed with its execution context, so avoid holding the click tool open while the caller
  // needs to issue Page.handleJavaScriptDialog.
  if (runtime.dialogs.has(page.sessionId)) return
  await runtime.connection
    .send("Runtime.releaseObject", { objectId: element.objectId }, page.sessionId)
    .catch(() => undefined)
}

export const evaluateLocatorReadOnly = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  source: string,
  arg: unknown
): Promise<T> => {
  assertReadOnlyFunction(source)
  const ids = await locatorBackendNodeIds(runtime, page, locator)
  if (ids.length !== 1) {
    throw new Error(
      ids.length === 0
        ? "Playwright locator resolved to 0 elements"
        : `Playwright strict mode violation: locator resolved to ${ids.length} elements`
    )
  }
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: ids[0] },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error("Playwright locator is no longer attached")
  try {
    const response = await runtime.connection.send<{
      result: { value?: unknown; description?: string }
      exceptionDetails?: { text?: string; exception?: { description?: string } }
    }>(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration: `function(arg){return Promise.resolve((${source})(this,arg));}`,
        arguments: [{ value: arg }],
        returnByValue: true,
        awaitPromise: true
      },
      page.sessionId
    )
    if (response.exceptionDetails !== undefined) {
      throw new Error(
        response.exceptionDetails.exception?.description ??
          response.exceptionDetails.text ??
          "Locator evaluation failed"
      )
    }
    return response.result.value as T
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
  }
}

export const callLocatorFunction = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = [],
  timeoutMs = 30_000
): Promise<T> => {
  const deadline = Date.now() + Math.max(0, Math.min(30_000, timeoutMs))
  let ids: number[] = []
  while (true) {
    ids = await locatorBackendNodeIds(runtime, page, locator)
    if (ids.length === 1) break
    if (ids.length > 1) {
      throw new Error(
        `Playwright strict mode violation: locator resolved to ${ids.length} elements`
      )
    }
    if (Date.now() >= deadline) throw new Error("Playwright locator resolved to 0 elements")
    await delay(100)
  }
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: ids[0] },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error("Playwright locator is no longer attached")
  try {
    return evaluatedValue<T>(
      await runtime.connection.send(
        "Runtime.callFunctionOn",
        {
          objectId,
          functionDeclaration,
          arguments: args.map((value) => ({ value })),
          returnByValue: true
        },
        page.sessionId
      )
    )
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
  }
}

export const locatorIsVisible = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown
): Promise<boolean> => {
  const ids = await locatorBackendNodeIds(runtime, page, locator)
  if (ids.length === 0) return false
  if (ids.length > 1) {
    throw new Error(`Playwright strict mode violation: locator resolved to ${ids.length} elements`)
  }
  return callLocatorFunction<boolean>(
    runtime,
    page,
    locator,
    "function(){const r=this.getBoundingClientRect(),s=getComputedStyle(this);return this.isConnected&&r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';}"
  )
}
