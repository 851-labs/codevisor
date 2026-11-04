import type { Tool } from "@modelcontextprotocol/server"
import { z } from "zod"

import snapshot from "./linear-mcp-tools.json" with { type: "json" }

export const linearTools: ReadonlyArray<Tool> = z
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

export const isLinearTool = (name: string): boolean =>
  linearTools.some((tool) => tool.name === name)
