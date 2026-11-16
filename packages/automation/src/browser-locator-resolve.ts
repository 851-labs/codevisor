import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { evaluatedValue } from "./browser-cdp.js"
import { cssLocatorFunction, semanticLocatorFunction } from "./browser-locator-page-functions.js"
import {
  type BrowserFrameStep,
  type BrowserLocator,
  parseLocator
} from "./browser-locator-parse.js"
import { queryShadowRoots } from "./browser-shadow-frames.js"
import { normalizeRef } from "./browser-snapshot.js"
import type { AXNode } from "./browser-snapshot.js"

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
      backendNodeIdsFromRootFunction(runtime, page, root, cssLocatorFunction, [selector])
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
  steps: ReadonlyArray<BrowserFrameStep>
): Promise<number[]> => {
  let current = [...roots]
  for (const step of steps) {
    const frames = await frameElementsWithin(runtime, page, current, step)
    if (frames.length === 0)
      throw new Error(`frameLocator(${JSON.stringify(step.css)}) found no frames`)
    const next: number[] = []
    for (const backendNodeId of frames) {
      const described = await runtime.connection.send<{
        node: { contentDocument?: { backendNodeId?: number } }
      }>("DOM.describeNode", { backendNodeId, depth: 1, pierce: true }, page.sessionId)
      const contentDocument = described.node.contentDocument?.backendNodeId
      if (contentDocument === undefined) {
        throw new Error(
          `frameLocator(${JSON.stringify(step.css)}) cannot access that frame document`
        )
      }
      next.push(contentDocument)
    }
    current = [...new Set(next)]
  }
  return current
}

const frameElementsWithin = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  step: BrowserFrameStep
): Promise<number[]> => {
  const reachable = await queryCssWithinRoots(runtime, page, roots, step.css)
  if (reachable.length > 0) return pickIndexed(reachable, step.index)
  return pickIndexed(await queryShadowRoots(runtime, page, roots, step.css), step.index)
}

export const frameElementIds = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  enclosing: ReadonlyArray<BrowserFrameStep>,
  step: BrowserFrameStep
): Promise<number[]> => {
  const document = await mainDocumentBackendNodeId(runtime, page)
  const roots = await resolveFrameRoots(runtime, page, [document], enclosing)
  return frameElementsWithin(runtime, page, roots, step)
}

const pickIndexed = (ids: number[], index: number | "last" | undefined): number[] => {
  if (index === undefined) return ids
  const position = index === "last" ? ids.length - 1 : index
  const picked = ids[position]
  return picked === undefined ? [] : [picked]
}

const frameOwnerFunction =
  "function(){const view=(this.ownerDocument||this).defaultView;return view&&view.frameElement||null;}"

const frameIdOfRoot = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  backendNodeId: number
): Promise<string | undefined> => {
  const root = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId },
    page.sessionId
  )
  const rootObjectId = root.object.objectId
  if (rootObjectId === undefined) return undefined
  const owner = await runtime.connection.send<{ result: { objectId?: string } }>(
    "Runtime.callFunctionOn",
    { objectId: rootObjectId, functionDeclaration: frameOwnerFunction, returnByValue: false },
    page.sessionId
  )
  const ownerObjectId = owner.result.objectId
  try {
    if (ownerObjectId === undefined) return undefined
    const described = await runtime.connection.send<{ node: { frameId?: string } }>(
      "DOM.describeNode",
      { objectId: ownerObjectId },
      page.sessionId
    )
    return described.node.frameId
  } finally {
    await releaseObjects(runtime, page, [rootObjectId, ownerObjectId])
  }
}

const releaseObjects = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  objectIds: ReadonlyArray<string | undefined>
): Promise<void> => {
  const held = objectIds.filter((objectId) => objectId !== undefined)
  await Promise.all(
    held.map((objectId) =>
      runtime.connection
        .send("Runtime.releaseObject", { objectId }, page.sessionId)
        .catch(() => undefined)
    )
  )
}

const accessibilityNodesForRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>
): Promise<AXNode[]> => {
  const frameIds = new Set(
    await Promise.all(roots.map((root) => frameIdOfRoot(runtime, page, root)))
  )
  const trees = await Promise.all(
    [...frameIds].map((frameId) =>
      runtime.connection.send<{ nodes: AXNode[] }>(
        "Accessibility.getFullAXTree",
        frameId === undefined ? {} : { frameId },
        page.sessionId
      )
    )
  )
  return trees.flatMap((tree) => tree.nodes)
}

const semanticLocatorKind = (locator: BrowserLocator) => {
  if (locator.label !== undefined) return "label"
  if (locator.placeholder !== undefined) return "placeholder"
  if (locator.testId !== undefined) return "testId"
  if (locator.altText !== undefined) return "altText"
  if (locator.title !== undefined) return "title"
  return "text"
}

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
    return (
      evaluatedValue(
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
      ) === true
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
  let roots: number[]
  if (inheritedRoots === undefined) roots = [await mainDocumentBackendNodeId(runtime, page)]
  else roots = [...inheritedRoots]
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
    const scoped = inheritedRoots !== undefined || (locator.frame?.length ?? 0) > 0
    if (scoped) ids = await filterBackendNodeIdsByRoots(runtime, page, [id], roots)
    else ids = [id]
  } else if (locator.css !== undefined) {
    ids = await queryCssWithinRoots(runtime, page, roots, locator.css)
  } else if (locator.role !== undefined) {
    const nodes = await accessibilityNodesForRoots(runtime, page, roots)
    const role = locator.role.toLocaleLowerCase()
    const expectedName = locator.name
    const exact = locator.exact === true
    const candidates = [
      ...new Set(
        nodes
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
    const kind = semanticLocatorKind(locator)
    const expected =
      locator.label ??
      locator.placeholder ??
      locator.testId ??
      locator.altText ??
      locator.title ??
      locator.text ??
      ""
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
  return pickIndexed(ids, locator.index)
}
