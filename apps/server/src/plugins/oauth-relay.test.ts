import { createHash } from "node:crypto"

import { describe, expect, it } from "vitest"

import type { CloudServerControl } from "../server-context-types.js"
import { makeOAuthRelay } from "./oauth-relay.js"
import { fakeCloud, type CloudReply } from "./plugin-test-support.js"

const cloudUrl = "https://cloud.example"

const signedIn = (reply: CloudReply = () => ({ redirectUri: `${cloudUrl}/oauth/callback` })) =>
  fakeCloud(reply)

const relayOn = (cloud: CloudServerControl | undefined) =>
  makeOAuthRelay({ cloud, appScheme: "codevisor-dev" })

describe("OAuth relay", () => {
  it("registers the flow under the hash of its state and hands back Cloud's callback", async () => {
    const { cloud, requests } = signedIn()

    const agent = await relayOn(cloud).register("server-1.state-a")
    const app = await relayOn(cloud).register("server-1.state-b", { app: "codevisor" })

    expect([agent, app]).toEqual([`${cloudUrl}/oauth/callback`, `${cloudUrl}/oauth/callback`])
    expect(requests).toEqual([
      {
        method: "POST",
        path: "/api/machine/oauth-flows",
        body: {
          flowId: createHash("sha256").update("server-1.state-a").digest("base64url"),
          app: "codevisor-dev",
          opensApp: false
        }
      },
      {
        method: "POST",
        path: "/api/machine/oauth-flows",
        body: expect.objectContaining({ app: "codevisor", opensApp: true })
      }
    ])
  })

  it("keeps sign-in local when the machine isn't signed in to Cloud or Cloud can't take it", async () => {
    const offline = fakeCloud()
    const failing = signedIn(() => {
      throw new Error("Cloud request failed (422)")
    })

    const notLinked = await relayOn({ ...offline.cloud, deviceId: () => undefined }).register("s")
    const refused = await relayOn(failing.cloud).register("s", {
      accepted: ["https://cloud.other/oauth/callback"]
    })

    expect([notLinked, refused]).toEqual([undefined, undefined])
    expect(offline.requests).toEqual([])
  })

  it("asks Cloud about a client's fixed redirects only when one could be a Cloud callback", async () => {
    const { cloud, requests } = signedIn(() => ({
      redirectUri: `${cloudUrl}/oauth/plugins/callback`
    }))
    const accepted = ["http://localhost", `${cloudUrl}/oauth/plugins/callback`]

    const through = await relayOn(cloud).register("s-1", { accepted })
    const loopbackOnly = await relayOn(cloud).register("s-2", { accepted: ["http://localhost"] })

    expect([through, loopbackOnly]).toEqual([`${cloudUrl}/oauth/plugins/callback`, undefined])
    expect(requests).toEqual([
      expect.objectContaining({ body: expect.objectContaining({ redirectUris: accepted }) })
    ])
  })
})
