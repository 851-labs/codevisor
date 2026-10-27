import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import type { PluginAppView } from "./mcp-plugin-apps.js"

export interface PluginAppViewStore {
  readonly save: (view: PluginAppView) => Promise<void>
  readonly get: (viewId: string) => Promise<PluginAppView | undefined>
  readonly prune: () => Promise<void>
}

export const APP_VIEW_RETENTION_MS = 30 * 24 * 60 * 60_000

export const makePluginAppViewStore = (
  dataDir: string,
  now: () => number = Date.now
): PluginAppViewStore => {
  const directory = join(dataDir, "plugin-app-views")
  const fileFor = (viewId: string): string => join(directory, `${viewId}.json`)

  return {
    save: async (view) => {
      await mkdir(directory, { recursive: true })
      await writeFile(fileFor(view.viewId), JSON.stringify(view), { mode: 0o600 })
    },
    get: async (viewId) => {
      if (!viewIdPattern.test(viewId)) return undefined
      const raw = await readFile(fileFor(viewId), "utf8").catch(() => undefined)
      if (raw === undefined) return undefined
      return parsedView(raw)
    },
    prune: async () => {
      const names = await readdir(directory).catch(() => [])
      const cutoff = now() - APP_VIEW_RETENTION_MS
      await Promise.all(names.map((name) => removeIfOlder(join(directory, name), cutoff)))
    }
  }
}

const viewIdPattern = /^[0-9a-f-]{36}$/

const ViewSchema = z.object({
  viewId: z.string(),
  machineId: z.string(),
  sessionId: z.string(),
  serverId: z.string(),
  serverName: z.string(),
  toolName: z.string(),
  resourceUri: z.string(),
  accountId: z.string().exactOptional(),
  toolInput: z.record(z.string(), z.unknown()),
  toolResult: CallToolResultSchema,
  createdAt: z.string()
})

const parsedView = (raw: string): PluginAppView | undefined => {
  try {
    return ViewSchema.parse(JSON.parse(raw))
  } catch {
    return undefined
  }
}

const removeIfOlder = async (path: string, cutoff: number): Promise<void> => {
  const info = await stat(path).catch(() => undefined)
  if (info === undefined || info.mtimeMs >= cutoff) return
  await rm(path, { force: true })
}
