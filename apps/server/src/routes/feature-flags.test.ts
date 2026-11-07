import { FeatureFlagsResponse } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, makeServices, readWebSocketEvents, startWithApp } from "../test-support.js"
import { field } from "./response-test-support.js"

const put = (enabled: boolean) => ({ method: "PUT", body: JSON.stringify({ enabled }) })

const enabledIds = async (server: Awaited<ReturnType<typeof startWithApp>>) => {
  const { body } = await jsonRequest(server, "/v1/feature-flags")
  return Schema.decodeUnknownSync(FeatureFlagsResponse)(body)
    .flags.filter((flag) => flag.enabled)
    .map((flag) => flag.id)
}

describe("/v1/feature-flags", () => {
  it("lists every flag off until it is turned on, and publishes the change to the apps", async () => {
    const server = await startWithApp((await makeServices("server-flags")).services)
    expect(await enabledIds(server)).toEqual([])

    const turnedOn = await jsonRequest(server, "/v1/feature-flags/bots", put(true))
    expect(turnedOn.body).toMatchObject({ id: "bots", title: "Bots", enabled: true })
    expect(await enabledIds(server)).toEqual(["bots"])

    const [event] = await readWebSocketEvents(server, 1, 0)
    expect(field(event, "kind")).toBe("sync.changed")
    expect(field(event, "payload")).toMatchObject({
      namespace: "feature-flags",
      entries: [{ key: "bots", value: true }]
    })
  })

  it("wins over a device write stamped ahead of this machine's clock", async () => {
    const server = await startWithApp((await makeServices("server-flags-skew")).services)
    const ahead = { wallMs: Date.now() + 86_400_000, counter: 0, deviceId: "fast-mac" }
    await jsonRequest(server, "/v1/sync/feature-flags", {
      method: "PUT",
      body: JSON.stringify({ entries: [{ key: "gmailPlugin", value: true, timestamp: ahead }] })
    })
    expect(await enabledIds(server)).toEqual(["gmailPlugin"])

    await jsonRequest(server, "/v1/feature-flags/gmailPlugin", put(false))
    expect(await enabledIds(server)).toEqual([])
  })

  it("rejects flags it doesn't know, naming the ones it does", async () => {
    const server = await startWithApp((await makeServices("server-flags-unknown")).services)
    const response = await jsonRequest(server, "/v1/feature-flags/robots", put(true))
    expect(response.status).toBe(404)
    expect(field(response.body, "error")).toBe(
      "Unknown feature flag: robots. Known flags: bots, developerMode, gmailPlugin"
    )
  })
})
