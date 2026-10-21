import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { jsonRequest, start } from "../test-support.js"

describe("browser-use routes", () => {
  it("has no stored browser choice and tracks the live Chrome relay", async () => {
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

    expect(initial.body).not.toHaveProperty("preferredBrowser")
    expect(
      (
        await jsonRequest(server, "/v1/browser-use", {
          method: "PATCH",
          body: JSON.stringify({ preferredBrowser: "managed" })
        })
      ).status
    ).toBe(404)

    const extension = async (): Promise<WebSocket> => {
      const socket = new WebSocket(
        `${server.url.replace("http:", "ws:")}/v1/browser-use/extension/socket`,
        { headers: { Origin: `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}` } }
      )
      socket.on("message", (data: Buffer) => {
        const command: unknown = JSON.parse(data.toString())
        const id =
          typeof command === "object" && command !== null && "id" in command ? command.id : -1
        socket.send(JSON.stringify({ id, result: { targetInfos: [] } }))
      })
      await new Promise<void>((resolve, reject) => {
        socket.once("open", resolve)
        socket.once("error", reject)
      })
      return socket
    }
    const replaced = await extension()
    const replacedClosed = new Promise((resolve) => replaced.once("close", resolve))
    const socket = await extension()
    await replacedClosed
    expect((await jsonRequest(server, "/v1/browser-use")).body).toMatchObject({
      chromeConnected: true
    })
    socket.close()
  })

  it("hands Mac app browser host sockets to the host registry", async () => {
    const { server } = await start()
    const host = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/browser-use/host/socket`)
    const closed = new Promise<number>((resolve) => host.once("close", resolve))
    await new Promise<void>((resolve, reject) => {
      host.once("open", resolve)
      host.once("error", reject)
    })
    host.send("not a hello")
    expect(await closed).toBe(1008)
  })
})
