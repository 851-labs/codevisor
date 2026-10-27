import type {
  PluginCapabilities,
  PluginEventDigest,
  PluginIngress,
  PluginPane,
  PluginSkillDigest,
  PluginToolDigest,
  PluginToolEffects
} from "@codevisor/api"
import type { Client } from "@modelcontextprotocol/sdk/client/index.js"
import type {
  ClientCapabilities,
  ServerCapabilities,
  Tool,
  ToolAnnotations
} from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import { appResourceUri } from "./mcp-plugin-apps.js"
import { pluginSkills, type PluginSkill } from "./mcp-plugin-skill-manifest.js"

export const PLUGIN_EXTENSIONS = {
  events: "io.modelcontextprotocol/events",
  skills: "io.modelcontextprotocol/skills",
  ui: "io.modelcontextprotocol/ui",
  panes: "dev.codevisor/panes",
  webhooks: "dev.codevisor/webhooks"
} as const

export const PLUGIN_CLIENT_CAPABILITIES: ClientCapabilities = {
  extensions: {
    [PLUGIN_EXTENSIONS.events]: {},
    [PLUGIN_EXTENSIONS.skills]: {},
    [PLUGIN_EXTENSIONS.ui]: { mimeTypes: ["text/html;profile=mcp-app"] },
    [PLUGIN_EXTENSIONS.panes]: {},
    [PLUGIN_EXTENSIONS.webhooks]: {}
  }
}

export interface DiscoveredPlugin {
  readonly capabilities: PluginCapabilities
  readonly skills: ReadonlyArray<PluginSkill>
}

export const discoverPlugin = async (
  client: Client,
  tools: ReadonlyArray<Tool>
): Promise<DiscoveredPlugin> => {
  const declared = client.getServerCapabilities()
  const events = await listedEvents(client, declared)
  const skills = await listedSkills(client, declared)

  return {
    capabilities: {
      tools: tools.map(toolDigest),
      events,
      skills: skills.map(skillDigest),
      panes: declaredPanes(declared),
      ingress: declaredIngress(declared)
    },
    skills
  }
}

export const toolEffects = (
  annotations: ToolAnnotations | undefined
): PluginToolEffects | undefined => {
  if (annotations === undefined) return undefined
  if (annotations.readOnlyHint === true) return "read"
  if (annotations.openWorldHint === true) return "external-write"
  return "write"
}

const maxListPages = 100

const PageSchema = z.looseObject({ nextCursor: z.string().optional() })

const EventEntrySchema = z.looseObject({
  name: z.string(),
  description: z.string().optional()
})

const EventsPageSchema = PageSchema.extend({ events: z.array(EventEntrySchema) })

const SkillsPageSchema = PageSchema.extend({ skills: z.array(z.unknown()) })

const PanesSchema = z.looseObject({
  panes: z.array(z.object({ type: z.string(), title: z.string(), resourceUri: z.string() }))
})

const IngressSchema = z.looseObject({
  ingress: z.array(z.object({ name: z.string(), title: z.string().optional() }))
})

const ResultSchema = z.looseObject({})

const toolDigest = (tool: Tool): PluginToolDigest => {
  const effects = toolEffects(tool.annotations)
  return {
    name: tool.name,
    ...(tool.description === undefined ? {} : { description: tool.description }),
    ...(effects === undefined ? {} : { effects }),
    ...(appResourceUri(tool) === undefined ? {} : { app: true })
  }
}

const skillDigest = (skill: PluginSkill): PluginSkillDigest => ({
  name: skill.name,
  ...(skill.description === undefined ? {} : { description: skill.description })
})

const declares = (declared: ServerCapabilities | undefined, extension: string): boolean =>
  declared?.extensions?.[extension] !== undefined

const listedEvents = async (
  client: Client,
  declared: ServerCapabilities | undefined
): Promise<ReadonlyArray<PluginEventDigest>> => {
  if (!declares(declared, PLUGIN_EXTENSIONS.events)) return []

  const pages = await listPages(client, "events/list", EventsPageSchema)
  return pages.flatMap((page) =>
    page.events.map((event) => ({
      name: event.name,
      ...(event.description === undefined ? {} : { description: event.description })
    }))
  )
}

const listedSkills = async (
  client: Client,
  declared: ServerCapabilities | undefined
): Promise<ReadonlyArray<PluginSkill>> => {
  if (!declares(declared, PLUGIN_EXTENSIONS.skills)) return []

  const pages = await listPages(client, "skills/list", SkillsPageSchema)
  return pluginSkills(pages.flatMap((page) => page.skills))
}

const listPages = async <Page extends z.infer<typeof PageSchema>>(
  client: Client,
  method: string,
  schema: z.ZodType<Page>
): Promise<ReadonlyArray<Page>> => {
  const pages: Page[] = []
  let cursor: string | undefined
  try {
    do {
      const result = await client.request(
        { method, params: cursor === undefined ? {} : { cursor } },
        ResultSchema
      )
      const page = schema.parse(result)
      pages.push(page)
      cursor = page.nextCursor
    } while (cursor !== undefined && pages.length < maxListPages)
  } catch {
    return []
  }
  return pages
}

const declaredPanes = (declared: ServerCapabilities | undefined): ReadonlyArray<PluginPane> =>
  PanesSchema.safeParse(declared?.extensions?.[PLUGIN_EXTENSIONS.panes]).data?.panes ?? []

const declaredIngress = (declared: ServerCapabilities | undefined): ReadonlyArray<PluginIngress> =>
  IngressSchema.safeParse(declared?.extensions?.[PLUGIN_EXTENSIONS.webhooks]).data?.ingress.map(
    (ingress) => ({
      name: ingress.name,
      ...(ingress.title === undefined ? {} : { title: ingress.title })
    })
  ) ?? []
