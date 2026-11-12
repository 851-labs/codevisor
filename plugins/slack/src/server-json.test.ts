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

import { requiredUserScopes } from "./slack-check.js"
import { createSlackServer } from "./slack-server.js"
import { slackTools } from "./slack-tool-catalog.js"

const serverJson: unknown = JSON.parse(
  readFileSync(new URL("../server.json", import.meta.url), "utf8")
)

const plugin = z
  .object({
    _meta: z.object({
      "dev.codevisor/plugin": z.object({
        accounts: z.object({
          fields: z.array(z.object({ key: z.string() })),
          guide: z.object({
            steps: z.array(
              z.object({
                fields: z.array(z.string()).optional(),
                link: z.object({ query: z.record(z.string(), z.unknown()).optional() }).optional()
              })
            )
          })
        }),
        capabilities: z.object({
          tools: z.array(z.object({ name: z.string(), effects: z.string() }))
        })
      })
    })
  })
  .transform((server) => server._meta["dev.codevisor/plugin"])
  .parse(serverJson)

const manifest = z
  .object({
    oauth_config: z.object({ scopes: z.object({ user: z.array(z.string()) }) }),
    settings: z.object({
      event_subscriptions: z.object({ request_url: z.string(), user_events: z.array(z.string()) })
    })
  })
  .parse(plugin.accounts.guide.steps[0]?.link?.query?.manifest_json)

it("publishes a server.json whose capability digest matches what the server serves", async () => {
  const { client } = await connectClient(createSlackServer({ clock: manualClock() }))

  expect(advertisedCapabilities(serverJson)).toEqual(await servedCapabilities(client))
  expect(serverJson).toMatchObject({
    name: "dev.codevisor/slack",
    version: client.getServerVersion()?.version,
    _meta: {
      "dev.codevisor/plugin": {
        bundled: "slack",
        entry: "dist/main.js",
        featureFlag: "slackPlugin",
        ageRating: expect.toBeOneOf([4, 9, 13, 16, 18])
      }
    }
  })
  await client.close()
})

it("labels each tool's effects from its hints", () => {
  const effects = new Map(plugin.capabilities.tools.map((tool) => [tool.name, tool.effects]))

  for (const tool of slackTools)
    expect([tool.name, effects.get(tool.name)]).toEqual([tool.name, effectsOf(tool.annotations)])
})

it("creates the Slack app with exactly the scopes the account check requires and the events it relays", () => {
  expect(manifest.oauth_config.scopes.user.toSorted()).toEqual(requiredUserScopes.toSorted())
  expect(manifest.settings.event_subscriptions).toEqual({
    request_url: "{{ingress.slack}}",
    user_events: [
      "message.channels",
      "message.groups",
      "message.im",
      "message.mpim",
      "reaction_added"
    ]
  })
})

it("asks for every account field in exactly one setup step", () => {
  const asked = plugin.accounts.guide.steps.flatMap((step) => step.fields ?? [])

  expect(asked.toSorted()).toEqual(plugin.accounts.fields.map((field) => field.key).toSorted())
})

const effectsOf = (hints: Tool["annotations"]) => {
  if (hints?.readOnlyHint === true) return "read"
  if (hints?.openWorldHint === true) return "external-write"
  return "write"
}
