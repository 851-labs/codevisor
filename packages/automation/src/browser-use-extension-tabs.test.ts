import { once } from "node:events"
import { rmSync, mkdtempSync, readFileSync } from "node:fs"
import type { AddressInfo } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import WebSocket, { WebSocketServer } from "ws"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("Browser Use extension tab lifecycle", () => {
  it("prepares an unpacked extension for the active development server", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-relay-config-"))
    directories.push(directory)
    const provider = makeBrowserUseProvider(directory)
    try {
      provider.configureExtensionRelay("http://127.0.0.1:60704")
      const extension = provider.status().developmentExtensionPath
      expect(extension).toBeDefined()
      expect(readFileSync(join(extension!, "relay-config.js"), "utf8")).toContain(
        "ws://127.0.0.1:60704/v1/browser-use/extension/socket"
      )
    } finally {
      await provider.close()
    }
  })

  it("waits for a newly created extension tab to become discoverable", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-new-tab-"))
    directories.push(directory)
    const provider = makeBrowserUseProvider(directory)
    const relay = new WebSocketServer({ host: "127.0.0.1", port: 0 })
    await once(relay, "listening")
    const serverSocket = once(relay, "connection")
    const client = new WebSocket(
      `ws://127.0.0.1:${(relay.address() as AddressInfo).port.toString()}`
    )
    let creates = 0
    let targetPolls = 0
    const extensionCommands: string[] = []
    client.on("message", (data) => {
      const request = JSON.parse(data.toString()) as {
        id: number
        method: string
        params?: Readonly<Record<string, unknown>>
        sessionId?: string
      }
      let result: unknown = {}
      if (request.method === "Target.createTarget") {
        creates += 1
        result = { targetId: "created-tab" }
      } else if (request.method === "Target.getTargets") {
        targetPolls += 1
        result = {
          targetInfos: [
            {
              targetId: "existing-tab",
              type: "page",
              title: "Existing",
              url: "https://example.com/"
            },
            ...(targetPolls < 2
              ? []
              : [
                  {
                    targetId: "created-tab",
                    type: "page",
                    title: "Emojis",
                    url: "https://emojis.com/"
                  }
                ])
          ]
        }
      } else if (request.method === "Target.attachToTarget") {
        result = { sessionId: "tab:created-tab" }
      } else if (request.method.startsWith("Codevisor.")) {
        extensionCommands.push(request.method)
        if (request.method === "Codevisor.clipboard.readText") {
          result = { text: "extension clipboard" }
        }
        if (request.method === "Codevisor.armDownload") {
          setTimeout(() => {
            client.send(
              JSON.stringify({
                method: "Browser.downloadWillBegin",
                sessionId: request.sessionId,
                params: {
                  guid: "download-1",
                  url: "https://emojis.com/fixture.txt",
                  suggestedFilename: "fixture.txt",
                  filePath: "/tmp/fixture.txt"
                }
              })
            )
            client.send(
              JSON.stringify({
                method: "Browser.downloadProgress",
                sessionId: request.sessionId,
                params: {
                  guid: "download-1",
                  state: "completed",
                  filePath: "/tmp/fixture.txt"
                }
              })
            )
          }, 0)
        }
      }
      client.send(JSON.stringify({ id: request.id, result }))
    })
    await once(client, "open")
    const [socket] = await serverSocket
    provider.acceptExtensionConnection(socket as WebSocket)

    try {
      const context = { sessionId: "new-tab-test", projectId: "new-tab-test" }
      provider.setSessionBackend(context.sessionId, "extension")
      const response = await provider.invoke(context, "tabs", {
        action: "new",
        url: "https://emojis.com/"
      })
      const content = response.content[0]
      if (content?.type !== "text") throw new Error("Missing tab result")
      const result = JSON.parse(content.text) as {
        tabs: Array<{ selected: boolean; url: string }>
      }

      expect(creates).toBe(1)
      expect(targetPolls).toBe(2)
      expect(result.tabs).toContainEqual(
        expect.objectContaining({ selected: true, url: "https://emojis.com/" })
      )

      const wrote = await provider.invoke(context, "clipboard.writeText", {
        text: "extension clipboard"
      })
      expect(wrote.isError).not.toBe(true)
      const read = await provider.invoke(context, "clipboard.readText", {})
      if (read.content[0]?.type !== "text") throw new Error("Missing extension clipboard")
      expect(JSON.parse(read.content[0].text)).toEqual({ text: "extension clipboard" })

      const download = await provider.invoke(context, "playwright.waitForEvent", {
        event: "download",
        timeoutMs: 1_000
      })
      if (download.content[0]?.type !== "text") throw new Error("Missing extension download")
      const downloadValue = JSON.parse(download.content[0].text) as { downloadId: string }
      const path = await provider.invoke(context, "playwright.downloadPath", {
        downloadId: downloadValue.downloadId,
        timeoutMs: 1_000
      })
      if (path.content[0]?.type !== "text") throw new Error("Missing extension download path")
      expect(JSON.parse(path.content[0].text)).toEqual({ path: "/tmp/fixture.txt" })
      expect(extensionCommands).toEqual([
        "Codevisor.clipboard.writeText",
        "Codevisor.clipboard.readText",
        "Codevisor.armDownload"
      ])
    } finally {
      await provider.close()
      client.close()
      await new Promise<void>((resolve) => relay.close(() => resolve()))
    }
  })

  it("reattaches an extension tab after detach events and stale-session races", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-session-recovery-"))
    directories.push(directory)
    const provider = makeBrowserUseProvider(directory)
    const relay = new WebSocketServer({ host: "127.0.0.1", port: 0 })
    await once(relay, "listening")
    const serverSocket = once(relay, "connection")
    const client = new WebSocket(
      `ws://127.0.0.1:${(relay.address() as AddressInfo).port.toString()}`
    )
    let attachCount = 0
    let rejectNextSessionCommand: string | undefined
    const evaluatedSessions: string[] = []
    client.on("message", (data) => {
      const request = JSON.parse(data.toString()) as {
        id: number
        method: string
        params?: Readonly<Record<string, unknown>>
        sessionId?: string
      }
      if (request.method === "Target.getTargets") {
        client.send(
          JSON.stringify({
            id: request.id,
            result: {
              targetInfos: [
                {
                  targetId: "recoverable-tab",
                  type: "page",
                  title: "Recoverable",
                  url: "https://example.com/"
                }
              ]
            }
          })
        )
        return
      }
      if (request.method === "Target.attachToTarget") {
        attachCount += 1
        client.send(
          JSON.stringify({ id: request.id, result: { sessionId: "tab:recoverable-tab" } })
        )
        return
      }
      if (request.method === "Runtime.evaluate") {
        evaluatedSessions.push(request.sessionId ?? "missing")
        if (rejectNextSessionCommand !== undefined) {
          const message = rejectNextSessionCommand
          rejectNextSessionCommand = undefined
          client.send(
            JSON.stringify({
              id: request.id,
              error: { message }
            })
          )
          return
        }
      }
      client.send(JSON.stringify({ id: request.id, result: {} }))
    })
    await once(client, "open")
    const [socket] = await serverSocket
    provider.acceptExtensionConnection(socket as WebSocket)

    try {
      const context = { sessionId: "session-recovery-test", projectId: "session-recovery-test" }
      provider.setSessionBackend(context.sessionId, "extension")
      const claimed = await provider.invoke(context, "tabs", {
        action: "select",
        id: "recoverable-tab"
      })
      expect(claimed.isError).not.toBe(true)

      const evaluate = () =>
        provider.invoke(context, "cdp.send", {
          method: "Runtime.evaluate",
          params: { expression: "document.title", returnByValue: true }
        })

      expect((await evaluate()).isError).not.toBe(true)
      expect(attachCount).toBe(1)

      await new Promise<void>((resolve, reject) => {
        client.send(
          JSON.stringify({
            method: "Target.detachedFromTarget",
            params: { sessionId: "tab:recoverable-tab", reason: "replaced_with_devtools" }
          }),
          (cause) => (cause == null ? resolve() : reject(cause))
        )
      })
      await new Promise((resolve) => setTimeout(resolve, 10))

      const detachEvents = await provider.invoke(context, "cdp.readEvents", {
        afterSequence: 0,
        methods: ["Target.detachedFromTarget"],
        target: { sessionId: "tab:recoverable-tab" }
      })
      if (detachEvents.content[0]?.type !== "text") throw new Error("Missing detach events")
      expect(JSON.parse(detachEvents.content[0].text)).toMatchObject({
        events: [
          {
            method: "Target.detachedFromTarget",
            params: { sessionId: "tab:recoverable-tab", reason: "replaced_with_devtools" },
            source: { sessionId: "tab:recoverable-tab", targetId: "recoverable-tab" }
          }
        ]
      })

      expect((await evaluate()).isError).not.toBe(true)
      expect(attachCount).toBe(2)

      rejectNextSessionCommand = "Unknown Codevisor tab session"
      expect((await evaluate()).isError).not.toBe(true)
      expect(attachCount).toBe(3)

      rejectNextSessionCommand = "Detached while handling command."
      const ambiguousDetach = await evaluate()
      expect(ambiguousDetach).toMatchObject({
        isError: true,
        content: [{ type: "text", text: "Detached while handling command." }]
      })
      expect(attachCount).toBe(3)
      expect(evaluatedSessions).toEqual([
        "tab:recoverable-tab",
        "tab:recoverable-tab",
        "tab:recoverable-tab",
        "tab:recoverable-tab",
        "tab:recoverable-tab"
      ])
    } finally {
      await provider.close()
      client.close()
      await new Promise<void>((resolve) => relay.close(() => resolve()))
    }
  })
})
