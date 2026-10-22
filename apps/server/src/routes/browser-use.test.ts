import { spawn } from "node:child_process"
import { writeFileSync } from "node:fs"
import { dirname } from "node:path"

import {
  CODEVISOR_BROWSER_EXTENSION_ID,
  ensureNativeHostSecret,
  requireServerResource
} from "@codevisor/automation"
import { describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import type { RunningCodevisorServer } from "../server.js"
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

  it("relays Chrome through the native messaging host on the port the server recorded", async () => {
    const { server } = await start()
    const dataDir = await serverDataDir(server)
    ensureNativeHostSecret(dataDir)
    writeFileSync(
      `${dataDir}/server-port.json`,
      JSON.stringify({ port: Number(new URL(server.url).port), pid: process.pid, bootId: "test" })
    )
    const host = spawn(
      process.execPath,
      [requireServerResource("native-host/codevisor-native-host.mjs", "native host"), dataDir],
      { stdio: "pipe" }
    )
    const exited = new Promise((resolve) => host.once("exit", resolve))
    const probed = Promise.withResolvers<void>()
    host.stdout.on(
      "data",
      nativeMessageReader((message) => {
        if (typeof message !== "string") return
        const id = commandId(message)
        host.stdin.write(nativeMessage(JSON.stringify({ id, result: { targetInfos: [] } })))
        probed.resolve()
      })
    )

    await probed.promise
    await vi.waitFor(
      async () =>
        expect((await jsonRequest(server, "/v1/browser-use")).body).toMatchObject({
          chromeConnected: true
        }),
      { timeout: 10_000 }
    )

    host.stdin.end()
    await exited
  })

  it("refuses native host sockets that skip the handshake or come from a web page", async () => {
    const { server } = await start()
    ensureNativeHostSecret(await serverDataDir(server))
    const url = `${server.url.replace("http:", "ws:")}/v1/browser-use/extension/native`

    const silent = new WebSocket(url)
    silent.once("message", () => silent.send(JSON.stringify({ id: 1, result: {} })))
    const silentClosed = new Promise((resolve) => silent.once("close", resolve))
    const fromPage = new WebSocket(url, { headers: { Origin: "https://example.com" } })
    const fromPageOutcome = new Promise((resolve) => {
      fromPage.once("open", () => resolve("opened"))
      fromPage.once("error", () => resolve("refused"))
    })

    expect(await silentClosed).toBe(1008)
    expect(await fromPageOutcome).toBe("refused")
  })
})

const serverDataDir = async (server: RunningCodevisorServer): Promise<string> => {
  const { body } = await jsonRequest(server, "/v1/browser-use")
  const path =
    typeof body === "object" && body !== null && "developmentExtensionPath" in body
      ? String(body.developmentExtensionPath)
      : ""
  return dirname(dirname(path))
}

const commandId = (message: string): number => {
  const command: unknown = JSON.parse(message)
  return typeof command === "object" && command !== null && "id" in command
    ? Number(command.id)
    : -1
}

const nativeMessage = (message: unknown): Buffer => {
  const body = Buffer.from(JSON.stringify(message), "utf8")
  const header = Buffer.alloc(4)
  header.writeUInt32LE(body.length)
  return Buffer.concat([header, body])
}

const nativeMessageReader = (onMessage: (message: unknown) => void) => {
  let buffered = Buffer.alloc(0)
  return (data: Buffer) => {
    buffered = Buffer.concat([buffered, data])
    while (buffered.length >= 4 && buffered.length >= 4 + buffered.readUInt32LE(0)) {
      const length = buffered.readUInt32LE(0)
      onMessage(JSON.parse(buffered.subarray(4, 4 + length).toString("utf8")))
      buffered = buffered.subarray(4 + length)
    }
  }
}
