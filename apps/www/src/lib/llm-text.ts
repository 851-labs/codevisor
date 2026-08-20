import { llms } from "fumadocs-core/source/llms"

import { source } from "./source"

const responseHeaders = {
  "Cache-Control": "public, max-age=0, s-maxage=3600",
  "Content-Type": "text/markdown; charset=utf-8"
}

export async function getPageMarkdown(slugs: string[], pageUrl: string) {
  const resolvedSource = await source.get()
  const page = resolvedSource.getPage(slugs)
  if (!page) return

  const heading = `# ${page.data.title} (${pageUrl})`
  if (page.type === "docs") {
    return `${heading}\n\n${await page.data.getText("processed")}`
  }

  const props = page.data.getOpenAPIPageProps()
  const document = props.payload.bundled as Record<string, unknown>
  const sections = [heading]

  if (page.data.description) sections.push(page.data.description)

  for (const item of props.operations ?? []) {
    const pathItem = asRecord(asRecord(document.paths)?.[item.path])
    const operation = asRecord(pathItem?.[item.method])
    if (!operation) continue

    sections.push(`## ${item.method.toUpperCase()} ${item.path}`, ...operationSummary(operation))
  }

  for (const item of props.webhooks ?? []) {
    const pathItem = asRecord(asRecord(document.webhooks)?.[item.name])
    const operation = asRecord(pathItem?.[item.method])
    if (!operation) continue

    sections.push(
      `## Webhook: ${item.method.toUpperCase()} ${item.name}`,
      ...operationSummary(operation)
    )
  }

  sections.push(
    "## OpenAPI definition",
    "```json",
    JSON.stringify(openApiFragment(document, props), null, 2),
    "```"
  )
  return sections.filter(Boolean).join("\n\n")
}

export async function getLlmsIndex(requestUrl: string) {
  const resolvedSource = await source.get()
  const origin = new URL(requestUrl).origin

  return llms(resolvedSource)
    .index()
    .replace(/\]\((\/docs(?:\/[^)]*)?)\)/g, `](${origin}$1.md)`)
}

export function markdownResponse(markdown: string | undefined) {
  if (!markdown) {
    return new Response("Not found", {
      status: 404,
      headers: { "Content-Type": "text/plain; charset=utf-8" }
    })
  }

  return new Response(markdown, { headers: responseHeaders })
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return
  return value as Record<string, unknown>
}

function operationSummary(operation: Record<string, unknown>) {
  const summary = typeof operation.summary === "string" ? operation.summary : undefined
  const description = typeof operation.description === "string" ? operation.description : undefined
  return [summary, description].filter((value): value is string => Boolean(value))
}

function openApiFragment(
  document: Record<string, unknown>,
  props: {
    operations?: { path: string; method: string }[]
    webhooks?: { name: string; method: string }[]
  }
) {
  const fragment: Record<string, unknown> = {}
  for (const key of [
    "openapi",
    "swagger",
    "info",
    "jsonSchemaDialect",
    "servers",
    "security",
    "tags",
    "externalDocs"
  ]) {
    if (document[key] !== undefined) fragment[key] = document[key]
  }

  const paths = asRecord(document.paths)
  if (paths && props.operations?.length) {
    fragment.paths = Object.fromEntries(
      [...new Set(props.operations.map((item) => item.path))]
        .filter((path) => paths[path] !== undefined)
        .map((path) => [path, paths[path]])
    )
  }

  const webhooks = asRecord(document.webhooks)
  if (webhooks && props.webhooks?.length) {
    fragment.webhooks = Object.fromEntries(
      [...new Set(props.webhooks.map((item) => item.name))]
        .filter((name) => webhooks[name] !== undefined)
        .map((name) => [name, webhooks[name]])
    )
  }

  if (document.components !== undefined) fragment.components = document.components
  return fragment
}
