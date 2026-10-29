import { describe, expect, it } from "vitest"

import { cloudInboxApi } from "./cloud-inbox-api.js"

const recordingCloud = (reply: unknown) => {
  const requests: Array<string> = []
  const api = cloudInboxApi(async (method, path, body) => {
    requests.push(`${method} ${path}${body === undefined ? "" : ` ${JSON.stringify(body)}`}`)
    return reply
  })
  return { api, requests }
}

describe("cloud inbox api", () => {
  it("asks the cloud for a plugin's inbox and returns its id and public URL", async () => {
    const { api, requests } = recordingCloud({ id: "inbox-1", url: "https://in.example/i/1" })
    const target = { plugin: "dev.codevisor/alerts", accountId: "account-1", ingress: "alerts" }

    expect(await api.ensure(target)).toEqual({ id: "inbox-1", url: "https://in.example/i/1" })
    expect(requests).toEqual([`POST /api/machine/inboxes ${JSON.stringify(target)}`])
  })

  it("subscribes and unsubscribes this device by the inbox's encoded id", async () => {
    const { api, requests } = recordingCloud(undefined)

    await api.subscribe("inbox/1")
    await api.unsubscribe("inbox/1")

    expect(requests).toEqual([
      "PUT /api/machine/inboxes/inbox%2F1/devices/self",
      "DELETE /api/machine/inboxes/inbox%2F1/devices/self"
    ])
  })

  it("routes an inbox by key and keeps only the string settings the cloud returns", async () => {
    const { api, requests } = recordingCloud({ config: { topic: "projects/p/topics/t", ttl: 7 } })
    const bare = recordingCloud({})

    expect(await api.route("inbox/1", "gmail", "abc")).toEqual({ topic: "projects/p/topics/t" })
    expect(await bare.api.route("inbox-2", "gmail", "abc")).toEqual({})
    expect(requests).toEqual(['PUT /api/machine/inboxes/inbox%2F1/routes/gmail {"key":"abc"}'])
  })

  it("deletes an inbox", async () => {
    const { api, requests } = recordingCloud(undefined)

    await api.remove("inbox/1")

    expect(requests).toEqual(["DELETE /api/machine/inboxes/inbox%2F1"])
  })
})
