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

import { createSentryServer } from "./sentry-server.js"
import { sentryTools } from "./sentry-tool-catalog.js"

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
  const { client } = await connectClient(createSentryServer({ clock: manualClock() }))

  expect(advertisedCapabilities(serverJson)).toEqual(await servedCapabilities(client))
  expect(serverJson).toMatchObject({
    name: "dev.codevisor/sentry",
    version: client.getServerVersion()?.version,
    _meta: {
      "dev.codevisor/plugin": {
        bundled: "sentry",
        entry: "dist/main.js",
        featureFlag: "sentryPlugin",
        replaces: "io.sentry/mcp",
        ageRating: expect.toBeOneOf([4, 9, 13, 16, 18]),
        accounts: {
          oauth: {
            client: "installed",
            provider: "sentry",
            redirectUrl: "https://cloud.codevisor.dev/oauth/plugins/callback"
          },
          fields: []
        }
      }
    }
  })
  await client.close()
})

it("labels each tool's effects from Sentry's own hints", () => {
  const effects = new Map(toolDigests.parse(serverJson).map((tool) => [tool.name, tool.effects]))

  for (const tool of sentryTools)
    expect([tool.name, effects.get(tool.name)]).toEqual([tool.name, effectsOf(tool.annotations)])
})

const effectsOf = (hints: Tool["annotations"]) => {
  if (hints?.readOnlyHint === true) return "read"
  if (hints?.openWorldHint === true) return "external-write"
  return "write"
}
