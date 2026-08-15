import { delay, evaluatedValue } from "./browser-cdp.js"
import {
  assertReadOnlyFunction,
  type BrowserRuntime,
  type PageHandle,
  type ResolvedElement
} from "./browser-cdp-engine.js"
import { normalizeRef, type AXNode } from "./browser-snapshot.js"

interface BrowserLocator {
  readonly ref?: string
  readonly css?: string
  readonly role?: string
  readonly name?: BrowserTextMatcher
  readonly label?: BrowserTextMatcher
  readonly placeholder?: BrowserTextMatcher
  readonly text?: BrowserTextMatcher
  readonly testId?: string
  readonly exact?: boolean
  readonly scope?: BrowserLocator
  readonly frame?: ReadonlyArray<string>
  readonly filters?: {
    readonly has?: BrowserLocator
    readonly hasNot?: BrowserLocator
    readonly hasText?: BrowserTextMatcher
    readonly hasNotText?: BrowserTextMatcher
    readonly visible?: boolean
  }
  readonly index?: number | "last"
  readonly and?: BrowserLocator
  readonly or?: BrowserLocator
}

type BrowserTextMatcher = string | { readonly regex: string; readonly flags?: string }

const parseTextMatcher = (value: unknown, label: string): BrowserTextMatcher => {
  if (typeof value === "string") return value
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be a string or regular expression`)
  }
  const input = value as Readonly<Record<string, unknown>>
  if (
    typeof input.regex !== "string" ||
    (input.flags !== undefined && typeof input.flags !== "string")
  ) {
    throw new Error(`${label} must contain regex and optional flags strings`)
  }
  try {
    new RegExp(input.regex, input.flags)
  } catch (cause) {
    throw new Error(
      `${label} is invalid: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  return {
    regex: input.regex,
    ...(typeof input.flags === "string" ? { flags: input.flags } : {})
  }
}

const parseLocator = (value: unknown, depth = 0): BrowserLocator => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("locator must be a Playwright-style locator object")
  }
  const locator = value as Readonly<Record<string, unknown>>
  const modes = ["ref", "css", "role", "label", "placeholder", "text", "testId"].filter((key) => {
    const candidate = locator[key]
    return typeof candidate === "string"
      ? candidate.length > 0
      : ["label", "placeholder", "text"].includes(key) &&
          candidate !== null &&
          typeof candidate === "object"
  })
  if (modes.length !== 1) {
    throw new Error(
      "locator must contain exactly one of ref, css, role, label, placeholder, text, or testId"
    )
  }
  if (locator.role === undefined && locator.name !== undefined) {
    throw new Error("locator.name is only valid with locator.role")
  }
  if (
    locator.frame !== undefined &&
    (!Array.isArray(locator.frame) ||
      !locator.frame.every((selector) => typeof selector === "string" && selector.length > 0))
  ) {
    throw new Error("locator.frame must be an array of frame selectors")
  }
  if (
    locator.index !== undefined &&
    locator.index !== "last" &&
    (typeof locator.index !== "number" || !Number.isInteger(locator.index) || locator.index < 0)
  ) {
    throw new Error("locator.index must be a non-negative integer or last")
  }
  const scope = locator.scope === undefined ? undefined : parseLocator(locator.scope, depth + 1)
  const and = locator.and === undefined ? undefined : parseLocator(locator.and, depth + 1)
  const or = locator.or === undefined ? undefined : parseLocator(locator.or, depth + 1)
  let filters: BrowserLocator["filters"]
  if (locator.filters !== undefined) {
    if (
      locator.filters === null ||
      typeof locator.filters !== "object" ||
      Array.isArray(locator.filters)
    ) {
      throw new Error("locator.filters must be an object")
    }
    const input = locator.filters as Readonly<Record<string, unknown>>
    if (input.visible !== undefined && typeof input.visible !== "boolean") {
      throw new Error("locator.filters.visible must be a boolean")
    }
    filters = {
      ...(input.has === undefined ? {} : { has: parseLocator(input.has, depth + 1) }),
      ...(input.hasNot === undefined ? {} : { hasNot: parseLocator(input.hasNot, depth + 1) }),
      ...(input.hasText === undefined
        ? {}
        : { hasText: parseTextMatcher(input.hasText, "locator.filters.hasText") }),
      ...(input.hasNotText === undefined
        ? {}
        : { hasNotText: parseTextMatcher(input.hasNotText, "locator.filters.hasNotText") }),
      ...(typeof input.visible === "boolean" ? { visible: input.visible } : {})
    }
  }
  return {
    ...(locator.ref === undefined ? {} : { ref: String(locator.ref) }),
    ...(locator.css === undefined ? {} : { css: String(locator.css) }),
    ...(locator.role === undefined ? {} : { role: String(locator.role) }),
    ...(locator.name === undefined ? {} : { name: parseTextMatcher(locator.name, "locator.name") }),
    ...(locator.label === undefined
      ? {}
      : { label: parseTextMatcher(locator.label, "locator.label") }),
    ...(locator.placeholder === undefined
      ? {}
      : { placeholder: parseTextMatcher(locator.placeholder, "locator.placeholder") }),
    ...(locator.text === undefined ? {} : { text: parseTextMatcher(locator.text, "locator.text") }),
    ...(locator.testId === undefined ? {} : { testId: String(locator.testId) }),
    ...(locator.exact === true ? { exact: true } : {}),
    ...(scope === undefined ? {} : { scope }),
    ...(locator.frame === undefined ? {} : { frame: locator.frame as string[] }),
    ...(filters === undefined ? {} : { filters }),
    ...(locator.index === undefined ? {} : { index: locator.index as number | "last" }),
    ...(and === undefined ? {} : { and }),
    ...(or === undefined ? {} : { or })
  }
}

const backendNodeIdsFromArrayObject = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  arrayObjectId: string
): Promise<number[]> => {
  const elementObjectIds: string[] = []
  try {
    const properties = await runtime.connection.send<{
      result: Array<{ name: string; value?: { objectId?: string } }>
    }>("Runtime.getProperties", { objectId: arrayObjectId, ownProperties: true }, page.sessionId)
    const ids: number[] = []
    for (const property of properties.result) {
      if (!/^\d+$/.test(property.name)) continue
      const objectId = property.value?.objectId
      if (objectId === undefined) continue
      elementObjectIds.push(objectId)
      const described = await runtime.connection.send<{ node: { backendNodeId: number } }>(
        "DOM.describeNode",
        { objectId },
        page.sessionId
      )
      ids.push(described.node.backendNodeId)
    }
    return [...new Set(ids)]
  } finally {
    await Promise.all(
      [arrayObjectId, ...elementObjectIds].map((objectId) =>
        runtime.connection
          .send("Runtime.releaseObject", { objectId }, page.sessionId)
          .catch(() => undefined)
      )
    )
  }
}

const backendNodeIdsFromRootFunction = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  rootBackendNodeId: number,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = []
): Promise<number[]> => {
  const root = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: rootBackendNodeId },
    page.sessionId
  )
  const rootObjectId = root.object.objectId
  if (rootObjectId === undefined) throw new Error("Locator root is no longer attached")
  try {
    const evaluated = await runtime.connection.send<{
      result: { objectId?: string; description?: string }
      exceptionDetails?: { text?: string; exception?: { description?: string } }
    }>(
      "Runtime.callFunctionOn",
      {
        objectId: rootObjectId,
        functionDeclaration,
        arguments: args.map((value) => ({ value })),
        returnByValue: false,
        awaitPromise: true
      },
      page.sessionId
    )
    const arrayObjectId = evaluated.result.objectId
    if (arrayObjectId === undefined) {
      const detail =
        evaluated.exceptionDetails?.exception?.description ??
        evaluated.exceptionDetails?.text ??
        evaluated.result.description ??
        "unknown"
      throw new Error(`Locator evaluation did not return elements: ${detail}`)
    }
    return backendNodeIdsFromArrayObject(runtime, page, arrayObjectId)
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId: rootObjectId }, page.sessionId)
      .catch(() => undefined)
  }
}

const mainDocumentBackendNodeId = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<number> => {
  const document = await runtime.connection.send<{ root: { backendNodeId: number } }>(
    "DOM.getDocument",
    { depth: 0, pierce: true },
    page.sessionId
  )
  return document.root.backendNodeId
}

const queryCssWithinRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  selector: string
): Promise<number[]> => {
  const ids = await Promise.all(
    roots.map((root) =>
      backendNodeIdsFromRootFunction(
        runtime,
        page,
        root,
        "function(selector){return [...this.querySelectorAll(selector)];}",
        [selector]
      )
    )
  )
  return [...new Set(ids.flat())]
}

const filterBackendNodeIdsByRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  ids: ReadonlyArray<number>,
  roots: ReadonlyArray<number>
): Promise<number[]> => {
  if (ids.length === 0 || roots.length === 0) return []
  const rootObjects = await Promise.all(
    roots.map((backendNodeId) =>
      runtime.connection.send<{ object: { objectId?: string } }>(
        "DOM.resolveNode",
        { backendNodeId },
        page.sessionId
      )
    )
  )
  const rootObjectIds = rootObjects.flatMap((root) =>
    root.object.objectId === undefined ? [] : [root.object.objectId]
  )
  try {
    const matches: number[] = []
    for (const backendNodeId of ids) {
      const candidate = await runtime.connection.send<{ object: { objectId?: string } }>(
        "DOM.resolveNode",
        { backendNodeId },
        page.sessionId
      )
      const candidateObjectId = candidate.object.objectId
      if (candidateObjectId === undefined) continue
      try {
        for (const rootObjectId of rootObjectIds) {
          const contained = evaluatedValue<boolean>(
            await runtime.connection.send(
              "Runtime.callFunctionOn",
              {
                objectId: rootObjectId,
                functionDeclaration:
                  "function(candidate){return candidate!==this&&(this.nodeType===9?this.documentElement?.contains(candidate)===true:this.contains(candidate));}",
                arguments: [{ objectId: candidateObjectId }],
                returnByValue: true
              },
              page.sessionId
            )
          )
          if (contained) {
            matches.push(backendNodeId)
            break
          }
        }
      } finally {
        await runtime.connection
          .send("Runtime.releaseObject", { objectId: candidateObjectId }, page.sessionId)
          .catch(() => undefined)
      }
    }
    return matches
  } finally {
    await Promise.all(
      rootObjectIds.map((objectId) =>
        runtime.connection
          .send("Runtime.releaseObject", { objectId }, page.sessionId)
          .catch(() => undefined)
      )
    )
  }
}

const resolveFrameRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  selectors: ReadonlyArray<string>
): Promise<number[]> => {
  let current = [...roots]
  for (const selector of selectors) {
    const frames = await queryCssWithinRoots(runtime, page, current, selector)
    if (frames.length === 0)
      throw new Error(`frameLocator(${JSON.stringify(selector)}) found no frames`)
    const next: number[] = []
    for (const backendNodeId of frames) {
      const described = await runtime.connection.send<{
        node: { contentDocument?: { backendNodeId?: number } }
      }>("DOM.describeNode", { backendNodeId, depth: 1, pierce: true }, page.sessionId)
      const contentDocument = described.node.contentDocument?.backendNodeId
      if (contentDocument === undefined) {
        throw new Error(
          `frameLocator(${JSON.stringify(selector)}) cannot access that frame document`
        )
      }
      next.push(contentDocument)
    }
    current = [...new Set(next)]
  }
  return current
}

const semanticLocatorFunction =
  "function(kind,expected,exact){const normalize=value=>String(value??'').replace(/\\s+/g,' ').trim();const matches=value=>{const actual=normalize(value);if(expected&&typeof expected==='object'&&typeof expected.regex==='string')return new RegExp(expected.regex,expected.flags||'').test(actual);return exact?actual===expected:actual.toLocaleLowerCase().includes(String(expected).toLocaleLowerCase());};if(kind==='label')return [...this.querySelectorAll('input,textarea,select,button,[contenteditable=true]')].filter(element=>{const doc=element.ownerDocument;const labelledBy=(element.getAttribute('aria-labelledby')||'').split(/\\s+/).filter(Boolean).map(id=>doc.getElementById(id)?.innerText||'').join(' ');const labels=element.labels?[...element.labels].map(label=>{const clone=label.cloneNode(true);clone.querySelectorAll('input,textarea,select,button,option,[contenteditable=true]').forEach(control=>control.remove());return clone.textContent||'';}):[];return[element.getAttribute('aria-label'),labelledBy,...labels].some(matches);});if(kind==='placeholder')return[...this.querySelectorAll('[placeholder]')].filter(element=>matches(element.getAttribute('placeholder')));if(kind==='testId')return[...this.querySelectorAll('[data-testid]')].filter(element=>matches(element.getAttribute('data-testid')));const candidates=[...this.querySelectorAll('*')].filter(element=>matches(element.innerText||element.textContent));return candidates.filter(element=>![...element.children].some(child=>matches(child.innerText||child.textContent))).slice(0,200);}" as const

const callBackendNodePredicate = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  backendNodeId: number,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = []
): Promise<boolean> => {
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) return false
  try {
    return evaluatedValue<boolean>(
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

export const locatorBackendNodeIds = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: unknown,
  inheritedRoots?: ReadonlyArray<number>,
  depth = 0
): Promise<number[]> => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  const locator = parseLocator(value, depth)
  let roots =
    inheritedRoots === undefined
      ? [await mainDocumentBackendNodeId(runtime, page)]
      : [...inheritedRoots]
  if (locator.frame !== undefined && locator.frame.length > 0) {
    roots = await resolveFrameRoots(runtime, page, roots, locator.frame)
  }
  if (locator.scope !== undefined) {
    roots = await locatorBackendNodeIds(runtime, page, locator.scope, roots, depth + 1)
  }
  let ids: number[]
  if (locator.ref !== undefined) {
    const snapshot = runtime.snapshots.get(page.target.targetId)
    if (snapshot === undefined) {
      throw new Error("No current Browser Use snapshot; call playwright.domSnapshot first")
    }
    const ref = normalizeRef(locator.ref)
    const id = snapshot.targets.get(ref)
    ids = id === undefined ? [] : await filterBackendNodeIdsByRoots(runtime, page, [id], roots)
  } else if (locator.css !== undefined) {
    ids = await queryCssWithinRoots(runtime, page, roots, locator.css)
  } else if (locator.role !== undefined) {
    const response = await runtime.connection.send<{ nodes: AXNode[] }>(
      "Accessibility.getFullAXTree",
      {},
      page.sessionId
    )
    const role = locator.role.toLocaleLowerCase()
    const expectedName = locator.name
    const exact = locator.exact === true
    const candidates = [
      ...new Set(
        response.nodes
          .filter((node) => {
            if (node.ignored || node.backendDOMNodeId === undefined) return false
            if (String(node.role?.value ?? "").toLocaleLowerCase() !== role) return false
            if (expectedName === undefined) return true
            const actual = String(node.name?.value ?? "")
              .replace(/\s+/g, " ")
              .trim()
            if (typeof expectedName !== "string") {
              return new RegExp(expectedName.regex, expectedName.flags).test(actual)
            }
            return exact
              ? actual === expectedName
              : actual.toLocaleLowerCase().includes(expectedName.toLocaleLowerCase())
          })
          .map((node) => node.backendDOMNodeId!)
      )
    ]
    ids = await filterBackendNodeIdsByRoots(runtime, page, candidates, roots)
  } else {
    const kind =
      locator.label !== undefined
        ? "label"
        : locator.placeholder !== undefined
          ? "placeholder"
          : locator.testId !== undefined
            ? "testId"
            : "text"
    const expected = locator.label ?? locator.placeholder ?? locator.testId ?? locator.text ?? ""
    const exact = locator.testId !== undefined || locator.exact === true
    const matches = await Promise.all(
      roots.map((root) =>
        backendNodeIdsFromRootFunction(runtime, page, root, semanticLocatorFunction, [
          kind,
          expected,
          exact
        ])
      )
    )
    ids = [...new Set(matches.flat())]
  }

  const filters = locator.filters
  if (filters !== undefined) {
    const filtered: number[] = []
    for (const id of ids) {
      const textMatches = await callBackendNodePredicate(
        runtime,
        page,
        id,
        "function(hasText,hasNotText,visible){const text=String(this.innerText||this.textContent||'').replace(/\\s+/g,' ').trim();const matches=expected=>expected&&typeof expected==='object'&&typeof expected.regex==='string'?new RegExp(expected.regex,expected.flags||'').test(text):text.toLocaleLowerCase().includes(String(expected).toLocaleLowerCase());const shown=(()=>{const r=this.getBoundingClientRect(),s=getComputedStyle(this);return this.isConnected&&r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';})();return(hasText===null||matches(hasText))&&(hasNotText===null||!matches(hasNotText))&&(visible===null||shown===visible);}",
        [filters.hasText ?? null, filters.hasNotText ?? null, filters.visible ?? null]
      )
      if (!textMatches) continue
      if (
        filters.has !== undefined &&
        (await locatorBackendNodeIds(runtime, page, filters.has, [id], depth + 1)).length === 0
      ) {
        continue
      }
      if (
        filters.hasNot !== undefined &&
        (await locatorBackendNodeIds(runtime, page, filters.hasNot, [id], depth + 1)).length > 0
      ) {
        continue
      }
      filtered.push(id)
    }
    ids = filtered
  }
  if (locator.and !== undefined) {
    const other = new Set(
      await locatorBackendNodeIds(runtime, page, locator.and, undefined, depth + 1)
    )
    ids = ids.filter((id) => other.has(id))
  }
  if (locator.or !== undefined) {
    ids = [
      ...new Set([
        ...ids,
        ...(await locatorBackendNodeIds(runtime, page, locator.or, undefined, depth + 1))
      ])
    ]
  }
  if (locator.index !== undefined) {
    const index = locator.index === "last" ? ids.length - 1 : locator.index
    ids = index < 0 || index >= ids.length ? [] : [ids[index]!]
  }
  return ids
}

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
