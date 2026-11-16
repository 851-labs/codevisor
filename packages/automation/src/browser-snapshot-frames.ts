import { attachTarget, type BrowserRuntime } from "./browser-cdp-engine.js"
import type { AXNode } from "./browser-snapshot.js"

export interface FrameAccessibility {
  readonly sessionId: string
  readonly nodes: ReadonlyMap<string, AXNode>
  readonly roots: ReadonlyArray<AXNode>
  readonly frames: ReadonlyMap<string, FrameAccessibility>
}

const maxFrames = 40
const maxFrameDepth = 6
const frameRoles = new Set(["Iframe", "IframePresentational"])

export const readFrameAccessibility = async (
  runtime: BrowserRuntime,
  sessionId: string
): Promise<FrameAccessibility> => readFrame(runtime, { sessionId }, { remaining: maxFrames }, 0)

interface FrameAddress {
  readonly sessionId: string
  readonly frameId?: string
}

interface FrameBudget {
  remaining: number
}

const readFrame = async (
  runtime: BrowserRuntime,
  address: FrameAddress,
  budget: FrameBudget,
  depth: number
): Promise<FrameAccessibility> => {
  const response = await runtime.connection.send<{ nodes: AXNode[] }>(
    "Accessibility.getFullAXTree",
    address.frameId === undefined ? {} : { frameId: address.frameId },
    address.sessionId
  )
  const owners = depth >= maxFrameDepth ? [] : response.nodes.filter(isFrameOwner)
  const children = await Promise.all(
    owners.map((owner) => readChildFrame(runtime, address.sessionId, owner, budget, depth))
  )
  return {
    sessionId: address.sessionId,
    nodes: new Map(response.nodes.map((node) => [node.nodeId, node])),
    roots: response.nodes.filter((node) => node.parentId === undefined),
    frames: new Map(children.flatMap((child) => (child === undefined ? [] : [child])))
  }
}

const isFrameOwner = (node: AXNode): boolean =>
  !node.ignored &&
  node.backendDOMNodeId !== undefined &&
  frameRoles.has(String(node.role?.value ?? ""))

const readChildFrame = async (
  runtime: BrowserRuntime,
  sessionId: string,
  owner: AXNode,
  budget: FrameBudget,
  depth: number
): Promise<readonly [string, FrameAccessibility] | undefined> => {
  if (budget.remaining <= 0) return undefined
  budget.remaining -= 1
  try {
    const address = await frameAddress(runtime, sessionId, owner.backendDOMNodeId!)
    if (address === undefined) return undefined
    return [owner.nodeId, await readFrame(runtime, address, budget, depth + 1)]
  } catch {
    return undefined
  }
}

const frameAddress = async (
  runtime: BrowserRuntime,
  sessionId: string,
  backendNodeId: number
): Promise<FrameAddress | undefined> => {
  const { node } = await runtime.connection.send<{
    node: { contentDocument?: object; frameId?: string }
  }>("DOM.describeNode", { backendNodeId, depth: 1, pierce: true }, sessionId)
  if (node.frameId === undefined) return undefined
  if (node.contentDocument !== undefined) return { sessionId, frameId: node.frameId }
  return { sessionId: await attachTarget(runtime, node.frameId, sessionId) }
}
