import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { routeBrowserFrame } from "./browser-frame.js"
import { locatorBackendNodeIds } from "./browser-locator-resolve.js"
import type { FrameAccessibility } from "./browser-snapshot-frames.js"
import { normalizeRef, type AXNode } from "./browser-snapshot.js"

export interface SnapshotStart {
  readonly tree: FrameAccessibility
  readonly node: AXNode
}

export interface SnapshotRoot {
  readonly sessionId: string
  readonly backendNodeId: number
}

export const snapshotRoot = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  root: unknown
): Promise<SnapshotRoot | undefined> => {
  if (root === undefined || root === null) return undefined
  if (typeof root === "string") return refElement(runtime, page, root)
  return locatorElement(runtime, page, root)
}

export const snapshotStarts = (
  tree: FrameAccessibility,
  root: SnapshotRoot | undefined
): SnapshotStart[] => {
  if (root === undefined) return tree.roots.map((node) => ({ tree, node }))

  const start = findStart(tree, root)
  if (start === undefined)
    throw new Error(
      "That element has no place in the accessibility tree, so there is nothing to show under it. Pick an element around it."
    )
  return [start]
}

const refElement = (runtime: BrowserRuntime, page: PageHandle, root: string): SnapshotRoot => {
  const snapshot = runtime.snapshots.get(page.snapshotKey ?? page.target.targetId)
  const ref = normalizeRef(root)
  const backendNodeId = snapshot?.targets.get(ref)
  if (snapshot === undefined || backendNodeId === undefined)
    throw new Error(`Unknown or stale root ${ref}; take a snapshot again and use a current ref`)
  return { sessionId: snapshot.frames.get(ref) ?? page.sessionId, backendNodeId }
}

const locatorElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  root: unknown
): Promise<SnapshotRoot> => {
  const routed = await routeBrowserFrame(runtime, page, root)
  const [backendNodeId] = await locatorBackendNodeIds(runtime, routed.page, routed.locator)
  if (backendNodeId === undefined) throw new Error("The root locator matched nothing on the page")
  return { sessionId: routed.page.sessionId, backendNodeId }
}

const findStart = (tree: FrameAccessibility, element: SnapshotRoot): SnapshotStart | undefined => {
  if (tree.sessionId === element.sessionId) {
    for (const node of tree.nodes.values())
      if (node.backendDOMNodeId === element.backendNodeId) return { tree, node }
  }
  for (const frame of tree.frames.values()) {
    const start = findStart(frame, element)
    if (start !== undefined) return start
  }
  return undefined
}
