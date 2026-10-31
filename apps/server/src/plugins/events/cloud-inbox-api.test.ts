import { describe, expect, it } from "vitest"

import { MachineApiError } from "../../infra/cloud-inbox.js"
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

  it("looks an inbox up by its target, and finds none when the cloud has none", async () => {
    const { api, requests } = recordingCloud({ id: "inbox-1" })
    const target = { plugin: "dev.codevisor/alerts", accountId: "a&b", ingress: "alerts" }
    const missing = cloudInboxApi(async () => {
      throw new MachineApiError(404, '{"error":"unknown inbox"}')
    })
    const down = cloudInboxApi(async () => {
      throw new MachineApiError(503, "unavailable")
    })

    expect(await api.find(target)).toBe("inbox-1")
    expect(requests).toEqual([
      "GET /api/machine/inboxes?plugin=dev.codevisor%2Falerts&accountId=a%26b&ingress=alerts"
    ])
    expect(await missing.find(target)).toBeUndefined()
    await expect(down.find(target)).rejects.toThrow("Cloud request failed (503)")
    await expect(recordingCloud({}).api.find(target)).rejects.toThrow(
      "The cloud didn't return an inbox"
    )
  })

  it("subscribes, unsubscribes and deletes an inbox by its encoded id", async () => {
    const { api, requests } = recordingCloud(undefined)

    await api.subscribe("inbox/1")
    await api.unsubscribe("inbox/1")
    await api.remove("inbox/1")

    expect(requests).toEqual([
      "PUT /api/machine/inboxes/inbox%2F1/devices/self",
      "DELETE /api/machine/inboxes/inbox%2F1/devices/self",
      "DELETE /api/machine/inboxes/inbox%2F1"
    ])
  })

  it("routes an inbox by key and keeps only the string settings the cloud returns", async () => {
    const { api, requests } = recordingCloud({ config: { topic: "projects/p/topics/t", ttl: 7 } })
    const bare = recordingCloud({})

    expect(await api.route("inbox/1", "gmail", "abc")).toEqual({ topic: "projects/p/topics/t" })
    expect(await bare.api.route("inbox-2", "gmail", "abc")).toEqual({})
    expect(requests).toEqual(['PUT /api/machine/inboxes/inbox%2F1/routes/gmail {"key":"abc"}'])
  })
})
