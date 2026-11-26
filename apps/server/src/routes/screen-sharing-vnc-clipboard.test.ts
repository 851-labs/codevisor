import { EventEmitter } from "node:events"
import { IncomingMessage } from "node:http"
import { Socket } from "node:net"

import { expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import { spliceVNCSocket, vncDesktopClipboard, VNC_DISPLAY_ID } from "./screen-sharing-vnc.js"
import { type DesktopClipboard, VNCClipboardBridge } from "./vnc-clipboard-bridge.js"
import { VNCControlArbiter } from "./vnc-control.js"

it("routes clipboard frames to the desktop's clipboard and everything else to the control lease", async () => {
  const texts: string[] = []
  const announcement = Promise.withResolvers<void>()
  const webSocket = Object.assign(new EventEmitter(), {
    bufferedAmount: 0,
    readyState: WebSocket.OPEN,
    close: () => undefined,
    send: (data: string | Buffer, _options: object, complete: () => void) => {
      if (typeof data === "string") texts.push(data)
      if (texts.length === 1) announcement.resolve()
      complete()
    }
  })
  let stopped = false
  const desktop: DesktopClipboard = {
    watch: () =>
      Promise.resolve(() => {
        stopped = true
      }),
    read: () => Promise.resolve([]),
    write: (content) => Promise.resolve(content)
  }
  const upstream = new Socket()
  const client = new Socket()
  const arbiter = new VNCControlArbiter()
  const receive = vi.spyOn(arbiter, "receive")
  try {
    const config = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
    spliceVNCSocket(
      config,
      new URL(`http://localhost/?displayId=${VNC_DISPLAY_ID}`),
      new IncomingMessage(client),
      client,
      Buffer.alloc(0),
      { handleUpgrade: (_request, _socket, _head, done) => done(webSocket) },
      { dial: () => upstream, arbiter, desktopClipboard: desktop, socketProblem: () => undefined }
    )
    await announcement.promise
    expect(texts).toEqual([JSON.stringify({ type: "clipboard-host", richContent: true })])

    webSocket.emit("message", Buffer.from('{"type":"clipboard-viewer","sharing":true}'), false)
    webSocket.emit(
      "message",
      Buffer.from(
        '{"type":"clipboard","version":1,"message":{"begin":{"id":"A","bytes":4,"richContent":true}}}'
      ),
      false
    )
    expect(receive).not.toHaveBeenCalled()
    expect(arbiter.mayControl(1)).toBe(true)
    expect(texts.at(-1)).toBe(
      JSON.stringify({ type: "clipboard", version: 1, message: { ack: { id: "A", nextIndex: 0 } } })
    )

    webSocket.emit("message", Buffer.from('{"type":"request","name":"Mac"}'), false)
    expect(receive).toHaveBeenCalledOnce()

    webSocket.emit("close")
    expect(stopped).toBe(true)
  } finally {
    receive.mockRestore()
    upstream.destroy()
    client.destroy()
  }
})

it("closes the bridge and stays silent when the desktop's clipboard can't be watched", async () => {
  const texts: string[] = []
  const webSocket = Object.assign(new EventEmitter(), {
    bufferedAmount: 0,
    readyState: WebSocket.OPEN,
    close: () => undefined,
    send: (data: string | Buffer, _options: object, complete: () => void) => {
      if (typeof data === "string") texts.push(data)
      complete()
    }
  })
  const bridgeClosed = Promise.withResolvers<void>()
  const close = vi
    .spyOn(VNCClipboardBridge.prototype, "close")
    .mockImplementation(() => bridgeClosed.resolve())
  const upstream = new Socket()
  const client = new Socket()
  try {
    const config = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
    spliceVNCSocket(
      config,
      new URL(`http://localhost/?displayId=${VNC_DISPLAY_ID}`),
      new IncomingMessage(client),
      client,
      Buffer.alloc(0),
      { handleUpgrade: (_request, _socket, _head, done) => done(webSocket) },
      {
        dial: () => upstream,
        arbiter: new VNCControlArbiter(),
        socketProblem: () => undefined,
        desktopClipboard: {
          watch: () => Promise.reject(new Error("xclip isn't installed")),
          read: () => Promise.resolve([]),
          write: (content) => Promise.resolve(content)
        }
      }
    )
    await bridgeClosed.promise
    expect(texts).toEqual([])
  } finally {
    close.mockRestore()
    upstream.destroy()
    client.destroy()
  }
})

it("only a desktop the server set up gets the clipboard bridge", () => {
  const desktop = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
  expect(vncDesktopClipboard({ ...desktop, display: 1 })).toBeUndefined()
  expect(vncDesktopClipboard({ ...desktop, desktop: "xfce", display: 1 })).toBeDefined()
  expect(vncDesktopClipboard({ ...desktop, desktop: "xfce" })).toBeUndefined()
})
