import type { Tool } from "@modelcontextprotocol/server"
import { z } from "zod"

import snapshot from "./sentry-mcp-tools.json" with { type: "json" }

export const sentryTools: ReadonlyArray<Tool> = z
  .array(
    z
      .object({
        name: z.string(),
        title: z.string().optional(),
        description: z.string().optional(),
        inputSchema: z.object({ type: z.literal("object") }).loose(),
        annotations: z
          .object({
            readOnlyHint: z.boolean().optional(),
            destructiveHint: z.boolean().optional(),
            idempotentHint: z.boolean().optional(),
            openWorldHint: z.boolean().optional()
          })
          .optional()
      })
      .loose()
  )
  .parse(snapshot)

export const isSentryTool = (name: string): boolean =>
  sentryTools.some((tool) => tool.name === name)
