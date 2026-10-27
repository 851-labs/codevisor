import type { DeliveredPluginAppContext, PluginAppContextRecord } from "@codevisor/db"

import { run, type CodevisorServerServices } from "../server-context.js"

export const APP_CONTEXT_MAX_CHARS = 8_000

export interface AppContextPrompt {
  readonly text: string
  readonly delivered: ReadonlyArray<DeliveredPluginAppContext>
}

export const withAppContexts = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string
): Promise<AppContextPrompt> => {
  const pending = await run(services.db.listPluginAppContexts(sessionId))
  const blocks = pending.flatMap(appContextBlock)
  const delivered = pending.map(({ viewId, revision }) => ({ viewId, revision }))
  if (blocks.length === 0) return { text, delivered }
  return { text: [...blocks, text].join("\n\n"), delivered }
}

export const markAppContextsDelivered = async (
  services: CodevisorServerServices,
  sessionId: string,
  delivered: ReadonlyArray<DeliveredPluginAppContext>
): Promise<void> => {
  if (delivered.length === 0) return
  await run(services.db.clearPluginAppContexts(sessionId, delivered))
}

const appContextBlock = (record: PluginAppContextRecord): ReadonlyArray<string> => {
  const body = cappedBody(contextBody(record.context))
  if (body === "") return []
  const attributes = [
    `plugin="${escapeAttribute(record.plugin)}"`,
    `tool="${escapeAttribute(record.tool)}"`,
    `viewId="${escapeAttribute(record.viewId)}"`
  ].join(" ")
  return [`<codevisor-app-context ${attributes}>\n${body}\n</codevisor-app-context>`]
}

const contextBody = (context: Readonly<Record<string, unknown>>): string => {
  const texts = contentTexts(context.content)
  const structured =
    context.structuredContent === undefined ? [] : [JSON.stringify(context.structuredContent)]
  return [...texts, ...structured].join("\n")
}

const contentTexts = (content: unknown): ReadonlyArray<string> => {
  if (!Array.isArray(content)) return []
  return content.flatMap((block: unknown) => {
    if (!isTextBlock(block)) return []
    return [block.text]
  })
}

const isTextBlock = (block: unknown): block is { readonly type: "text"; readonly text: string } =>
  typeof block === "object" &&
  block !== null &&
  Reflect.get(block, "type") === "text" &&
  typeof Reflect.get(block, "text") === "string"

const cappedBody = (body: string): string =>
  body.length <= APP_CONTEXT_MAX_CHARS ? body : `${body.slice(0, APP_CONTEXT_MAX_CHARS - 1)}…`

const escapeAttribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")
