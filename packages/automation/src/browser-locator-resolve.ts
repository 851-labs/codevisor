import { evaluatedValue } from "./browser-cdp.js"
import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { normalizeRef } from "./browser-snapshot.js"
import type { AXNode } from "./browser-snapshot.js"
import { parseLocator } from "./browser-locator-parse.js"

/// Resolving a locator to the backend node ids it matches, across frames and
/// shadow roots, with Playwright's strictness rules.

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
  const resolved = await Promise.all(
    [...roots, ...ids].map((backendNodeId) =>
      runtime.connection.send<{ object: { objectId?: string } }>(
        "DOM.resolveNode",
        { backendNodeId },
        page.sessionId
      )
    )
  )
  const rootObjects = resolved
    .slice(0, roots.length)
    .flatMap((result) => (result.object.objectId === undefined ? [] : [result.object.objectId]))
  const candidates = resolved
    .slice(roots.length)
    .flatMap((result) => (result.object.objectId === undefined ? [] : [result.object.objectId]))
  try {
    if (rootObjects.length === 0 || candidates.length === 0) return []
    const result = await runtime.connection.send<{ result: { objectId?: string } }>(
      "Runtime.callFunctionOn",
      {
        objectId: rootObjects[0],
        // The AX response is breadth-first, not document order. Resolve containment and
        // ordering together in the page so first()/nth() match the visible DOM order.
        functionDeclaration:
          "function(rootCount,...nodes){const roots=nodes.slice(0,rootCount);const contains=(root,node)=>{for(let current=node;current;current=current.getRootNode()?.host){if(current!==root&&root.contains(current))return true;}return false;};return nodes.slice(rootCount).filter(node=>roots.some(root=>contains(root,node))).sort((a,b)=>{const order=a.compareDocumentPosition(b);return order&1?0:order&2?1:order&4?-1:0;});}",
        arguments: [
          { value: rootObjects.length },
          ...[...rootObjects, ...candidates].map((objectId) => ({ objectId }))
        ],
        returnByValue: false
      },
      page.sessionId
    )
    if (result.result.objectId === undefined) throw new Error("Could not order locator matches")
    return await backendNodeIdsFromArrayObject(runtime, page, result.result.objectId)
  } finally {
    await Promise.all(
      [...rootObjects, ...candidates].map((objectId) =>
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
    const snapshot = runtime.snapshots.get(page.snapshotKey ?? page.target.targetId)
    if (snapshot === undefined) {
      throw new Error("No current Browser Use snapshot; call playwright.domSnapshot first")
    }
    const ref = normalizeRef(locator.ref)
    const id = snapshot.targets.get(ref)
    if (id === undefined) throw new Error(`Unknown or stale target ${ref}; take a fresh snapshot`)
    ids = await filterBackendNodeIdsByRoots(runtime, page, [id], roots)
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
