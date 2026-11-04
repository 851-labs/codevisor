import { readFileSync } from "node:fs"

import {
  advertisedCapabilities,
  connectClient,
  manualClock,
  servedCapabilities
} from "@codevisor/plugin-kit/test-support"
import type { Tool } from "@modelcontextprotocol/server"
import { expect, it } from "vitest"
import { z } from "zod"

import { createLinearServer } from "./linear-server.js"
import { linearTools } from "./linear-tool-catalog.js"

const serverJson: unknown = JSON.parse(
  readFileSync(new URL("../server.json", import.meta.url), "utf8")
)

const toolDigests = z
  .object({
    _meta: z.object({
      "dev.codevisor/plugin": z.object({
        capabilities: z.object({
          tools: z.array(z.object({ name: z.string(), effects: z.string() }))
        })
      })
    })
  })
  .transform((server) => server._meta["dev.codevisor/plugin"].capabilities.tools)

it("publishes a server.json whose capability digest matches what the server serves", async () => {
  const { client } = await connectClient(createLinearServer({ clock: manualClock() }))

  expect(advertisedCapabilities(serverJson)).toEqual(await servedCapabilities(client))
  expect(serverJson).toMatchObject({
    name: "dev.codevisor/linear",
    version: client.getServerVersion()?.version,
    _meta: {
      "dev.codevisor/plugin": {
        bundled: "linear",
        entry: "dist/main.js",
        ageRating: expect.toBeOneOf([4, 9, 13, 16, 18]),
        accounts: {
          oauth: {
            client: "installed",
            provider: "linear",
            redirectUrl: "https://cloud.codevisor.dev/oauth/plugins/callback"
          },
          fields: []
        }
      }
    }
  })
  await client.close()
})

it("labels each tool's effects from Linear's own hints", () => {
  const effects = new Map(toolDigests.parse(serverJson).map((tool) => [tool.name, tool.effects]))

  for (const tool of linearTools)
    expect([tool.name, effects.get(tool.name)]).toEqual([tool.name, effectsOf(tool.annotations)])
})

const effectsOf = (hints: Tool["annotations"]) => {
  if (hints?.readOnlyHint === true) return "read"
  if (hints?.openWorldHint === true) return "external-write"
  return "write"
}
