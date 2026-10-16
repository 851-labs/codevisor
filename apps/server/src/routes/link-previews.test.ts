import { describe, expect, it } from "vitest"

import type { LinkPreviewStore } from "../infra/link-previews.js"
import { makeServices, start, startWithApp } from "../test-support.js"

describe("link preview routes", () => {
  it("serves previews and their images, and 404s when there is none", async () => {
    const image = { contentType: "image/jpeg" as const, data: new Uint8Array([0xff, 0xd8, 0xff]) }
    const asked: Array<string> = []
    const linkPreviews: LinkPreviewStore = {
      preview: async (url) => {
        asked.push(url)
        return url === "https://a.test/" ? { url, title: "A" } : undefined
      },
      image: async (url) => {
        asked.push(url)
        return url === "https://a.test/" ? image : undefined
      }
    }
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, linkPreviews })
    const query = `url=${encodeURIComponent("https://a.test/")}`

    const preview = await fetch(`${server.url}/v1/link-previews?${query}`)
    expect(preview.status).toBe(200)
    expect(await preview.json()).toEqual({ url: "https://a.test/", title: "A" })
    const served = await fetch(`${server.url}/v1/link-previews/image?${query}`)
    expect(served.status).toBe(200)
    expect(served.headers.get("content-type")).toBe("image/jpeg")
    expect(served.headers.get("cache-control")).toBe("private, max-age=86400")
    expect(new Uint8Array(await served.arrayBuffer())).toEqual(image.data)

    expect((await fetch(`${server.url}/v1/link-previews?url=https%3A%2F%2Fb.test`)).status).toBe(
      404
    )
    expect(
      (await fetch(`${server.url}/v1/link-previews/image?url=https%3A%2F%2Fb.test`)).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/link-previews`)).status).toBe(400)
    expect(
      (await fetch(`${server.url}/v1/link-previews?${query}`, { method: "POST" })).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/link-previews/other?${query}`)).status).toBe(404)
    expect(asked).toEqual([
      "https://a.test/",
      "https://a.test/",
      "https://b.test",
      "https://b.test"
    ])
  })

  it("reports the routes unavailable without a preview store", async () => {
    const { server } = await start()
    expect((await fetch(`${server.url}/v1/link-previews?url=https%3A%2F%2Fa.test`)).status).toBe(
      501
    )
  })
})
