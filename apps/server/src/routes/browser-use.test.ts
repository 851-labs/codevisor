import { WebSocket } from "ws"
import { describe, expect, it } from "vitest"
import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
import { jsonRequest, start } from "../test-support.js"

describe("browser-use routes", () => {
  it("persists Browser Use selection and tracks the live Chrome relay", async () => {
    const { server } = await start()
    const initial = await jsonRequest(server, "/v1/browser-use")
    expect(initial.status).toBe(200)
    expect(initial.body).toMatchObject({
      chromeConnected: false,
      managedAvailable: expect.any(Boolean)
    })
    const extensionArchive = await fetch(`${server.url}/v1/browser-use/extension/archive`)
    expect(extensionArchive.status).toBe(200)
    expect(extensionArchive.headers.get("content-type")).toBe("application/zip")
    expect(
      Buffer.from(await extensionArchive.arrayBuffer())
        .subarray(0, 4)
        .toString("hex")
    ).toBe("504b0304")
    const extensionIcon = await fetch(`${server.url}/v1/browser-use/extension/icon`)
    expect(extensionIcon.status).toBe(200)
    expect(extensionIcon.headers.get("content-type")).toBe("image/png")
    expect(
      Buffer.from(await extensionIcon.arrayBuffer())
        .subarray(1, 4)
        .toString("utf8")
    ).toBe("PNG")

    const selected = await jsonRequest(server, "/v1/browser-use", {
      method: "PATCH",
      body: JSON.stringify({ preferredBrowser: "managed" })
    })
    expect(selected.body).toMatchObject({ preferredBrowser: "managed" })
    expect((await jsonRequest(server, "/v1/browser-use")).body).toMatchObject({
      preferredBrowser: "managed"
    })
    expect(
      (
        await jsonRequest(server, "/v1/browser-use", {
          method: "PATCH",
          body: JSON.stringify({ preferredBrowser: "firefox" })
        })
      ).status
    ).toBe(400)

    const socket = new WebSocket(
      `${server.url.replace("http:", "ws:")}/v1/browser-use/extension/socket`,
      { headers: { Origin: `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}` } }
    )
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve)
      socket.once("error", reject)
    })
    expect((await jsonRequest(server, "/v1/browser-use")).body).toMatchObject({
      chromeConnected: true
    })
    socket.close()
  })
})
