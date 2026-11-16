import { randomUUID } from "node:crypto"

import type { CallToolResult } from "@modelcontextprotocol/server"

import { pageInformation, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { readFrameAccessibility, type FrameAccessibility } from "./browser-snapshot-frames.js"

export interface AXValue {
  readonly value?: string | number | boolean
}

export interface AXProperty {
  readonly name: string
  readonly value?: AXValue
}

export interface AXNode {
  readonly nodeId: string
  readonly parentId?: string
  readonly childIds?: string[]
  readonly ignored: boolean
  readonly role?: AXValue
  readonly name?: AXValue
  readonly value?: AXValue
  readonly properties?: AXProperty[]
  readonly backendDOMNodeId?: number
}

const maxSnapshotLines = 2_000

export const snapshotPage = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  depthLimit: number
): Promise<CallToolResult> => {
  const tree = await readFrameAccessibility(runtime, page.sessionId)
  const outline = snapshotOutline(depthLimit, page.sessionId)
  for (const root of tree.roots) outline.visit(tree, root, 0)
  const snapshotId = randomUUID()
  runtime.snapshots.set(page.snapshotKey ?? page.target.targetId, {
    id: snapshotId,
    targets: outline.targets,
    frames: outline.frames
  })
  const info = await pageInformation(runtime, page)
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\nSnapshot: ${snapshotId}\nTitle: ${info.title}\n${outline.lines.join("\n")}${outline.truncated() ? "\n[Snapshot truncated; scope with locators or request a greater depth.]" : ""}`
      }
    ]
  }
}

export const normalizeRef = (target: unknown): string => {
  if (typeof target !== "string") throw new Error("target must be a ref from the latest snapshot")
  const match = target.match(/^e\d+$/)
  if (match === null) throw new Error("target must look like e12 and come from the latest snapshot")
  return match[0]
}

const snapshotOutline = (depthLimit: number, pageSessionId: string) => {
  const targets = new Map<string, number>()
  const frames = new Map<string, string>()
  const lines: string[] = []
  let truncated = false
  let nextRef = Number.parseInt(randomUUID().replaceAll("-", "").slice(0, 12), 16)

  const register = (tree: FrameAccessibility, node: AXNode): string | undefined => {
    if (!hasRef(node)) return undefined
    const ref = `e${nextRef++}`
    targets.set(ref, node.backendDOMNodeId!)
    if (tree.sessionId !== pageSessionId) frames.set(ref, tree.sessionId)
    return ref
  }

  const visit = (
    tree: FrameAccessibility,
    node: AXNode,
    depth: number,
    ancestorName = ""
  ): void => {
    if (depth > depthLimit || lines.length >= maxSnapshotLines) {
      truncated = true
      return
    }
    const normalizedName = normalized(node.name?.value)
    const omitted = isOmitted(node, normalizedName, ancestorName)
    if (!omitted) lines.push(outlineLine(node, depth, register(tree, node)))
    const childDepth = omitted ? depth : depth + 1
    for (const childId of node.childIds ?? []) {
      const child = tree.nodes.get(childId)
      if (child !== undefined) visit(tree, child, childDepth, normalizedName || ancestorName)
    }
    const frame = tree.frames.get(node.nodeId)
    for (const root of frame?.roots ?? []) visit(frame!, root, childDepth)
  }

  return { targets, frames, lines, visit, truncated: () => truncated }
}

const roleOf = (node: AXNode): string => String(node.role?.value ?? "node")

const normalized = (value: AXValue["value"]): string =>
  String(value ?? "")
    .replace(/\s+/g, " ")
    .trim()

const isOmitted = (node: AXNode, normalizedName: string, ancestorName: string): boolean => {
  const role = roleOf(node)
  return (
    node.ignored ||
    role === "InlineTextBox" ||
    (role === "generic" && normalizedName === "" && node.value?.value === undefined) ||
    (role === "StaticText" && normalizedName !== "" && normalizedName === ancestorName)
  )
}

const hasRef = (node: AXNode): boolean => {
  const role = roleOf(node)
  return (
    node.backendDOMNodeId !== undefined &&
    role !== "RootWebArea" &&
    role !== "InlineTextBox" &&
    (role !== "generic" || String(node.name?.value ?? "").trim().length > 0)
  )
}

const quoted = (value: AXValue["value"]): string => {
  const text = String(value ?? "")
    .replaceAll("\n", " ")
    .trim()
  return text.length === 0 ? "" : ` ${JSON.stringify(text.slice(0, 300))}`
}

const outlineLine = (node: AXNode, depth: number, ref: string | undefined): string => {
  const value = node.value?.value
  const flags = stateFlags(node)
  return (
    `${"  ".repeat(depth)}- ${roleOf(node)}${quoted(node.name?.value)}` +
    (ref === undefined ? "" : ` [ref=${ref}]`) +
    (value === undefined || value === ""
      ? ""
      : ` [value=${JSON.stringify(String(value).slice(0, 300))}]`) +
    (flags.length === 0 ? "" : ` [${flags.join(", ")}]`)
  )
}

const stateFlags = (node: AXNode): string[] => {
  const properties = new Map(
    (node.properties ?? []).map((property) => [property.name, property.value?.value])
  )
  const flags = ["disabled", "focused", "required", "readonly"].filter(
    (name) => properties.get(name) === true
  )
  for (const state of ["checked", "selected", "expanded"]) {
    const value = properties.get(state)
    if (value !== undefined) flags.push(`${state}=${String(value)}`)
  }
  return flags
}
