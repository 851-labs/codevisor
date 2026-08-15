import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { parseExpression } from "@babel/parser"
import type { ChildProcess } from "node:child_process"
import { delay, evaluatedValue, type CdpConnection } from "./browser-cdp.js"

export interface TargetInfo {
  readonly targetId: string
  readonly type: string
  readonly title: string
  readonly url: string
}

export interface BrowserSnapshot {
  readonly id: string
  readonly targets: ReadonlyMap<string, number>
}

export interface BrowserRuntime {
  readonly connection: CdpConnection
  readonly processHandle: ChildProcess | undefined
  readonly owned: boolean
  readonly sessions: Map<string, string>
  readonly snapshots: Map<string, BrowserSnapshot>
  readonly eventLog: Array<{
    readonly method: string
    readonly params: Readonly<Record<string, unknown>>
    readonly sequence: number
    readonly sessionId?: string
  }>
  readonly logs: Map<string, Array<Readonly<Record<string, unknown>>>>
  readonly dialogs: Map<string, Readonly<Record<string, unknown>>>
  readonly fileChoosers: Map<string, { readonly sessionId: string; readonly backendNodeId: number }>
  readonly downloads: Map<
    string,
    {
      readonly guid: string
      readonly url: string
      readonly suggestedFilename: string
      readonly path?: string
      readonly state?: string
    }
  >
  readonly eventDisposers: Array<() => void>
  eventSequence: number
  tabOrder: string[]
  queue: Promise<void>
}

export interface ResolvedElement {
  readonly backendNodeId: number
  readonly objectId: string
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

export interface PageHandle {
  readonly target: TargetInfo
  readonly sessionId: string
}

export const jsonResult = (value: unknown, isError = false): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  ...(isError ? { isError: true } : {})
})

export const pageResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: Readonly<Record<string, unknown>>
): Promise<CallToolResult> => {
  const dialog = runtime.dialogs.get(page.sessionId)
  // A modal JavaScript dialog pauses Runtime.evaluate in the page. Keep action results
  // nonblocking so the caller can immediately inspect and accept or dismiss the dialog.
  const info =
    dialog === undefined
      ? await pageInformation(runtime, page)
      : { url: page.target.url, title: page.target.title }
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\n${JSON.stringify(
          {
            ...value,
            page: info,
            ...(dialog === undefined ? {} : { dialogOpened: true })
          },
          null,
          2
        )}`
      }
    ]
  }
}

export const pageTargets = async (runtime: BrowserRuntime): Promise<TargetInfo[]> => {
  const response = await runtime.connection.send<{ targetInfos: TargetInfo[] }>("Target.getTargets")
  const targets = response.targetInfos.filter((target) => target.type === "page")
  const live = new Set(targets.map((target) => target.targetId))
  runtime.tabOrder = runtime.tabOrder.filter((id) => live.has(id))
  for (const target of targets) {
    if (!runtime.tabOrder.includes(target.targetId)) runtime.tabOrder.push(target.targetId)
  }
  const byId = new Map(targets.map((target) => [target.targetId, target]))
  return runtime.tabOrder.flatMap((id) => {
    const target = byId.get(id)
    return target === undefined ? [] : [target]
  })
}

export const waitForCreatedTarget = async (
  runtime: BrowserRuntime,
  targetId: string,
  requestedUrl: string
): Promise<TargetInfo[]> => {
  const deadline = Date.now() + 2_000
  let targets: TargetInfo[] = []
  do {
    targets = await pageTargets(runtime)
    if (targets.some((target) => target.targetId === targetId)) return targets
    await delay(25)
  } while (Date.now() < deadline)

  // Target.createTarget has already succeeded, so reporting failure here would encourage a
  // caller to create the same tab again. Preserve the known target in the response while Chrome
  // finishes publishing its URL through Target.getTargets.
  const created: TargetInfo = {
    targetId,
    type: "page",
    title: "",
    url: requestedUrl
  }
  if (!runtime.tabOrder.includes(targetId)) runtime.tabOrder.push(targetId)
  const byId = new Map(targets.map((target) => [target.targetId, target]))
  byId.set(targetId, created)
  return runtime.tabOrder.flatMap((id) => {
    const target = byId.get(id)
    return target === undefined ? [] : [target]
  })
}

export const attachTarget = async (runtime: BrowserRuntime, targetId: string): Promise<string> => {
  const existing = runtime.sessions.get(targetId)
  if (existing !== undefined) return existing
  const attached = await runtime.connection.send<{ sessionId: string }>("Target.attachToTarget", {
    targetId,
    flatten: true
  })
  runtime.sessions.set(targetId, attached.sessionId)
  await Promise.all([
    runtime.connection.send("Page.enable", {}, attached.sessionId),
    runtime.connection.send("Runtime.enable", {}, attached.sessionId),
    runtime.connection.send("DOM.enable", {}, attached.sessionId),
    runtime.connection.send("Accessibility.enable", {}, attached.sessionId),
    runtime.connection.send("Log.enable", {}, attached.sessionId).catch(() => undefined)
  ])
  return attached.sessionId
}

export const currentPage = async (
  runtime: BrowserRuntime,
  selectedTargets: Map<string, string>,
  sessionKey: string
): Promise<PageHandle> => {
  let targets = await pageTargets(runtime)
  if (targets.length === 0) {
    const created = await runtime.connection.send<{ targetId: string }>("Target.createTarget", {
      url: "about:blank"
    })
    selectedTargets.set(sessionKey, created.targetId)
    targets = await pageTargets(runtime)
  }
  const selected = selectedTargets.get(sessionKey)
  const target = targets.find((candidate) => candidate.targetId === selected) ?? targets[0]
  if (target === undefined) throw new Error("The browser has no page target")
  selectedTargets.set(sessionKey, target.targetId)
  return { target, sessionId: await attachTarget(runtime, target.targetId) }
}

export const evaluate = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  expression: string
): Promise<T> =>
  evaluatedValue<T>(
    await runtime.connection.send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      page.sessionId
    )
  )

export const assertReadOnlyFunction = (source: string): void => {
  let expression: unknown
  try {
    expression = parseExpression(source, {
      plugins: ["typescript"],
      allowAwaitOutsideFunction: true
    })
  } catch (cause) {
    throw new Error(
      `evaluate expects a JavaScript function: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  const mutatingMethods = new Set([
    "append",
    "appendChild",
    "before",
    "blur",
    "click",
    "close",
    "dispatchEvent",
    "focus",
    "insertAdjacentElement",
    "insertAdjacentHTML",
    "insertAdjacentText",
    "insertBefore",
    "open",
    "postMessage",
    "prepend",
    "remove",
    "removeAttribute",
    "removeChild",
    "replaceChildren",
    "replaceWith",
    "requestSubmit",
    "setAttribute",
    "submit",
    "write",
    "writeln"
  ])
  const seen = new WeakSet<object>()
  const visit = (node: unknown): void => {
    if (node === null || typeof node !== "object" || seen.has(node)) return
    seen.add(node)
    const candidate = node as Readonly<Record<string, unknown>>
    const type = candidate.type
    if (
      type === "AssignmentExpression" ||
      type === "UpdateExpression" ||
      type === "NewExpression"
    ) {
      throw new Error("evaluate is read-only and rejects assignment, update, and construction")
    }
    if (type === "UnaryExpression" && candidate.operator === "delete") {
      throw new Error("evaluate is read-only and rejects delete")
    }
    if (type === "CallExpression") {
      const callee = candidate.callee as Readonly<Record<string, unknown>> | undefined
      const property =
        callee?.type === "MemberExpression"
          ? (callee.property as Readonly<Record<string, unknown>> | undefined)
          : undefined
      const name =
        property?.type === "Identifier"
          ? property.name
          : property?.type === "StringLiteral"
            ? property.value
            : undefined
      if (typeof name === "string" && mutatingMethods.has(name)) {
        throw new Error(`evaluate is read-only and rejects ${name}()`)
      }
    }
    for (const [key, value] of Object.entries(candidate)) {
      if (key === "loc" || key === "start" || key === "end") continue
      if (Array.isArray(value)) {
        for (const item of value) visit(item)
      } else visit(value)
    }
  }
  visit(expression)
  const root = expression as { readonly type?: string }
  if (root.type !== "FunctionExpression" && root.type !== "ArrowFunctionExpression") {
    throw new Error("evaluate expects a function")
  }
}

export const evaluateReadOnly = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  source: string,
  arg: unknown
): Promise<T> => {
  assertReadOnlyFunction(source)
  const response = await runtime.connection.send<{
    result: { value?: unknown; description?: string }
    exceptionDetails?: { text?: string; exception?: { description?: string } }
  }>(
    "Runtime.evaluate",
    {
      expression: `Promise.resolve((${source})(${JSON.stringify(arg)}))`,
      returnByValue: true,
      awaitPromise: true
    },
    page.sessionId
  )
  if (response.exceptionDetails !== undefined) {
    throw new Error(
      response.exceptionDetails.exception?.description ??
        response.exceptionDetails.text ??
        "Page evaluation failed"
    )
  }
  return response.result.value as T
}

export const waitForCdpEvent = (
  runtime: BrowserRuntime,
  method: string,
  sessionId: string | undefined,
  timeoutMs: number
): Promise<Readonly<Record<string, unknown>>> =>
  new Promise((resolve, reject) => {
    let finished = false
    const stop = runtime.connection.on(
      method,
      (params) => {
        if (finished) return
        finished = true
        clearTimeout(timer)
        stop()
        resolve(params)
      },
      sessionId
    )
    const timer = setTimeout(() => {
      if (finished) return
      finished = true
      stop()
      reject(new Error(`Timed out waiting for ${method}`))
    }, timeoutMs)
    timer.unref?.()
  })

export const pageInformation = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<{ url: string; title: string }> =>
  evaluate(runtime, page, "({ url: location.href, title: document.title })")

export const waitForReady = async (runtime: BrowserRuntime, page: PageHandle): Promise<void> => {
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    const state = await evaluate<string>(runtime, page, "document.readyState").catch(
      () => "loading"
    )
    if (state === "interactive" || state === "complete") return
    await delay(100)
  }
  throw new Error("Timed out waiting for the page to become interactive")
}

export const grantClipboardPermissions = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<void> => {
  const info = await pageInformation(runtime, page)
  let origin: string
  try {
    origin = new URL(info.url).origin
  } catch {
    return
  }
  const params = {
    origin,
    permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"]
  }
  await runtime.connection
    .send("Browser.grantPermissions", params)
    .catch(() =>
      runtime.connection
        .send("Browser.grantPermissions", params, page.sessionId)
        .catch(() => undefined)
    )
}

export const actionResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  action: string,
  extra: Readonly<Record<string, unknown>> = {}
): Promise<CallToolResult> => {
  await delay(100)
  return pageResult(runtime, page, {
    action,
    path: "cdp",
    delivered: true,
    verified: false,
    effect: "unverifiable",
    next: "Call snapshot to confirm the effect and obtain fresh refs.",
    ...extra
  })
}

export const verifiedActionResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  action: string,
  extra: Readonly<Record<string, unknown>> = {}
): Promise<CallToolResult> => {
  await delay(50)
  return pageResult(runtime, page, {
    action,
    path: "cdp",
    delivered: true,
    verified: true,
    effect: "confirmed",
    ...extra
  })
}

export const numberArgument = (args: Readonly<Record<string, unknown>>, name: string): number => {
  const value = args[name]
  if (typeof value !== "number" || !Number.isFinite(value))
    throw new Error(`${name} must be a number`)
  return value
}

export const stringArgument = (args: Readonly<Record<string, unknown>>, name: string): string => {
  const value = args[name]
  if (typeof value !== "string") throw new Error(`${name} must be a string`)
  return value
}

export const booleanArgument = (args: Readonly<Record<string, unknown>>, name: string): boolean => {
  const value = args[name]
  if (typeof value !== "boolean") throw new Error(`${name} must be a boolean`)
  return value
}
