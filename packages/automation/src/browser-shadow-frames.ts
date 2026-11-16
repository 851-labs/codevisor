import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"

interface DomNode {
  readonly nodeId: number
  readonly backendNodeId: number
  readonly shadowRootType?: string
  readonly children?: ReadonlyArray<DomNode>
  readonly shadowRoots?: ReadonlyArray<DomNode>
  readonly contentDocument?: DomNode
}

export const queryShadowRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  selector: string
): Promise<number[]> => {
  const document = await runtime.connection.send<{ root: DomNode }>(
    "DOM.getDocument",
    { depth: -1, pierce: true },
    page.sessionId
  )
  const shadowRoots = roots.flatMap((root) =>
    shadowRootsUnder(nodeWithBackendId(document.root, root))
  )
  const matches = await Promise.all(
    shadowRoots.map((shadowRoot) => matchesWithin(runtime, page, shadowRoot.nodeId, selector))
  )
  return [...new Set(matches.flat())]
}

const matchesWithin = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  nodeId: number,
  selector: string
): Promise<number[]> => {
  const found = await runtime.connection
    .send<{ nodeIds: number[] }>("DOM.querySelectorAll", { nodeId, selector }, page.sessionId)
    .catch(() => ({ nodeIds: [] }))
  const described = await Promise.all(
    found.nodeIds.map((match) =>
      runtime.connection.send<{ node: { backendNodeId: number } }>(
        "DOM.describeNode",
        { nodeId: match },
        page.sessionId
      )
    )
  )
  return described.map(({ node }) => node.backendNodeId)
}

const nodeWithBackendId = (node: DomNode, backendNodeId: number): DomNode | undefined => {
  if (node.backendNodeId === backendNodeId) return node
  for (const child of [...treeChildren(node), ...frameDocument(node)]) {
    const found = nodeWithBackendId(child, backendNodeId)
    if (found !== undefined) return found
  }
  return undefined
}

const shadowRootsUnder = (node: DomNode | undefined): DomNode[] => {
  if (node === undefined) return []
  const own = (node.shadowRoots ?? []).filter((root) => root.shadowRootType !== "user-agent")
  return [...own, ...treeChildren(node).flatMap(shadowRootsUnder)]
}

const treeChildren = (node: DomNode): ReadonlyArray<DomNode> => [
  ...(node.children ?? []),
  ...(node.shadowRoots ?? [])
]

const frameDocument = (node: DomNode): ReadonlyArray<DomNode> =>
  node.contentDocument === undefined ? [] : [node.contentDocument]
