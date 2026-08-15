import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { pageInformation, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"

export interface AXValue {
  readonly value?: unknown
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

const quoted = (value: unknown): string => {
  const text = String(value ?? "")
    .replaceAll("\n", " ")
    .trim()
  return text.length === 0 ? "" : ` ${JSON.stringify(text.slice(0, 300))}`
}

export const snapshotPage = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  depthLimit: number
): Promise<CallToolResult> => {
  const response = await runtime.connection.send<{ nodes: AXNode[] }>(
    "Accessibility.getFullAXTree",
    {},
    page.sessionId
  )
  const nodes = new Map(response.nodes.map((node) => [node.nodeId, node]))
  const roots = response.nodes.filter((node) => node.parentId === undefined)
  const targets = new Map<string, number>()
  const lines: string[] = []
  let nextRef = 1
  const visit = (node: AXNode, depth: number): void => {
    if (depth > depthLimit || lines.length >= 2_000) return
    const role = String(node.role?.value ?? "node")
    const name = node.name?.value
    if (!node.ignored) {
      const ref =
        node.backendDOMNodeId !== undefined &&
        role !== "RootWebArea" &&
        role !== "InlineTextBox" &&
        (role !== "generic" || String(name ?? "").trim().length > 0)
          ? `e${nextRef++}`
          : undefined
      if (ref !== undefined) targets.set(ref, node.backendDOMNodeId!)
      const properties = new Map(
        (node.properties ?? []).map((property) => [property.name, property.value?.value])
      )
      const flags = [
        properties.get("disabled") === true ? "disabled" : undefined,
        properties.get("focused") === true ? "focused" : undefined,
        properties.get("required") === true ? "required" : undefined,
        properties.get("readonly") === true ? "readonly" : undefined
      ].filter((value): value is string => value !== undefined)
      const value = node.value?.value
      lines.push(
        `${"  ".repeat(depth)}- ${role}${quoted(name)}` +
          `${ref === undefined ? "" : ` [ref=${ref}]`}` +
          `${value === undefined || value === "" ? "" : ` [value=${JSON.stringify(String(value).slice(0, 300))}]`}` +
          `${flags.length === 0 ? "" : ` [${flags.join(", ")}]`}`
      )
    }
    for (const childId of node.childIds ?? []) {
      const child = nodes.get(childId)
      if (child !== undefined) visit(child, node.ignored ? depth : depth + 1)
    }
  }
  for (const root of roots) visit(root, 0)
  const snapshotId = randomUUID()
  runtime.snapshots.set(page.target.targetId, { id: snapshotId, targets })
  const info = await pageInformation(runtime, page)
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\nSnapshot: ${snapshotId}\nTitle: ${info.title}\n${lines.join("\n")}`
      }
    ]
  }
}

export const normalizeRef = (target: unknown): string => {
  if (typeof target !== "string") throw new Error("target must be a ref from the latest snapshot")
  const match = target.match(/\be\d+\b/)
  if (match === null) throw new Error("target must look like e12 and come from the latest snapshot")
  return match[0]
}
