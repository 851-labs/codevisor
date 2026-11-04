import { readFileSync } from "node:fs"

import {
  advertisedCapabilities,
  connectClient,
  servedCapabilities
} from "@codevisor/plugin-kit/test-support"
import { expect, it } from "vitest"

import { makeShopifyCli } from "./shopify-cli.js"
import { createShopifyServer } from "./shopify-server.js"
import { fakeShopifyCli } from "./shopify-test-support.js"

const serverJson: unknown = JSON.parse(
  readFileSync(new URL("../server.json", import.meta.url), "utf8")
)

it("publishes a server.json whose capability digest matches what the server serves", async () => {
  const cli = makeShopifyCli({
    locate: async () => ({ command: "shopify", args: [] }),
    run: fakeShopifyCli().run
  })
  const { client } = await connectClient(createShopifyServer(cli))

  expect(advertisedCapabilities(serverJson)).toEqual(await servedCapabilities(client))
  expect(serverJson).toMatchObject({
    name: "dev.codevisor/shopify",
    version: client.getServerVersion()?.version,
    _meta: {
      "dev.codevisor/plugin": {
        bundled: "shopify",
        entry: "dist/main.js",
        featureFlag: "shopifyPlugin",
        accounts: {
          oauth: { provider: "shopify", client: "plugin" },
          fields: [{ key: "store", required: true }]
        }
      }
    }
  })
  await client.close()
})
