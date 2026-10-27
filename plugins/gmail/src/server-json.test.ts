import { readFileSync } from "node:fs"

import {
  advertisedCapabilities,
  connectClient,
  manualClock,
  servedCapabilities
} from "@codevisor/plugin-kit/test-support"
import { expect, it } from "vitest"

import { createGmailServer } from "./gmail-server.js"

const serverJson: unknown = JSON.parse(
  readFileSync(new URL("../server.json", import.meta.url), "utf8")
)

it("publishes a server.json whose capability digest matches what the server serves", async () => {
  const { client } = await connectClient(createGmailServer({ clock: manualClock() }))

  expect(advertisedCapabilities(serverJson)).toEqual(await servedCapabilities(client))
  expect(serverJson).toMatchObject({
    name: "dev.codevisor/gmail",
    version: client.getServerVersion()?.version,
    _meta: {
      "dev.codevisor/plugin": {
        bundled: "gmail",
        entry: "dist/main.js",
        ageRating: expect.toBeOneOf([4, 9, 13, 16, 18])
      }
    }
  })
  await client.close()
})
