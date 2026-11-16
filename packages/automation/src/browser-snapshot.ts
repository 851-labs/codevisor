import { randomUUID } from "node:crypto"

import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  pageInformation,
  type BrowserRuntime,
  type BrowserSnapshot,
  type PageHandle
} from "./browser-cdp-engine.js"
import { pdfSnapshotNote, showsPdf } from "./browser-pdf.js"
import { readFrameAccessibility, type FrameAccessibility } from "./browser-snapshot-frames.js"
import { snapshotRoot, snapshotStarts } from "./browser-snapshot-scope.js"

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

export interface SnapshotRequest {
  readonly depth: number
  readonly root?: unknown
  readonly offset?: unknown
}

const windowLines = 2_000
const maxSnapshotLines = 30_000

export const snapshotPage = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  request: SnapshotRequest
): Promise<CallToolResult> => {
  const key = page.snapshotKey ?? page.target.targetId
  if (request.offset !== undefined)
    return snapshotResult(runtime, page, currentSnapshot(runtime, key), request.offset)

  const snapshot = await takeSnapshot(runtime, page, request)
  runtime.snapshots.set(key, snapshot)
  return snapshotResult(runtime, page, snapshot, 0)
}

const takeSnapshot = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  request: SnapshotRequest
): Promise<BrowserSnapshot> => {
  const root = await snapshotRoot(runtime, page, request.root)
  const tree = await readFrameAccessibility(runtime, page.sessionId)
  const outline = snapshotOutline(request.depth, page.sessionId)
  for (const start of snapshotStarts(tree, root)) outline.visit(start.tree, start.node, 0)
  return {
    id: randomUUID(),
    targets: outline.targets,
    frames: outline.frames,
    lines: outline.lines,
    clipped: outline.truncated()
  }
}

const currentSnapshot = (runtime: BrowserRuntime, key: string): BrowserSnapshot => {
  const snapshot = runtime.snapshots.get(key)
  if (snapshot === undefined)
    throw new Error(
      "The page changed since the last snapshot, so there is nothing to read on from. Take a new one with tab.getAXState()."
    )
  return snapshot
}

const snapshotResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  snapshot: BrowserSnapshot,
  offset: unknown
): Promise<CallToolResult> => {
  const start = lineOffset(offset, snapshot.lines.length)
  const shown = snapshot.lines.slice(start, start + windowLines)
  const info = await pageInformation(runtime, page)
  const pdf = await showsPdf(runtime, page)
  const text = [
    `Page URL: ${info.url}`,
    `Snapshot: ${snapshot.id}`,
    `Title: ${info.title}`,
    ...shown,
    ...windowNotes(snapshot, start, start + shown.length),
    ...(pdf ? [pdfSnapshotNote] : [])
  ].join("\n")
  return { content: [{ type: "text", text }] }
}

const lineOffset = (offset: unknown, total: number): number => {
  if (typeof offset !== "number" || !Number.isInteger(offset) || offset < 0)
    throw new Error("offset must be a line count from a snapshot's own note, such as 2000")
  if (offset > 0 && offset >= total)
    throw new Error(`offset ${offset} is past the end of the snapshot, which has ${total} lines`)
  return offset
}

const windowNotes = (snapshot: BrowserSnapshot, start: number, end: number): string[] => {
  const total = snapshot.lines.length
  const notes: string[] = []
  if (end < total)
    notes.push(
      `[Lines ${start + 1}-${end} of ${total}. Read on with tab.getAXState({ offset: ${end} }); the refs above stay valid. Or show one part of the page with tab.getAXState({ root }), where root is a ref or a locator.]`
    )
  else if (start > 0) notes.push(`[Lines ${start + 1}-${end} of ${total}; end of the snapshot.]`)
  if (snapshot.clipped)
    notes.push(
      `[Some of the page was left out: it is nested too deeply or runs past ${maxSnapshotLines} lines. Show one part of it with tab.getAXState({ root }), where root is a ref or a locator.]`
    )
  return notes
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
