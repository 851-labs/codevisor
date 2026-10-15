import { EventEmitter } from "node:events"
import { IncomingMessage } from "node:http"
import { Socket } from "node:net"

import { expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import { spliceVNCSocket, vncDisplayId } from "./screen-sharing-vnc.js"
import { VNCControlArbiter } from "./vnc-control.js"

it.each([4, 5])(
  "pauses at %i queued bytes and resumes only below the high-water mark",
  (queued) => {
    const completions: Array<() => void> = []
    const webSocket = Object.assign(new EventEmitter(), {
      bufferedAmount: 0,
      readyState: WebSocket.OPEN,
      close: () => undefined,
      send: vi.fn((chunk: Buffer, _options: { binary: boolean }, complete: () => void) => {
        webSocket.bufferedAmount += chunk.length
        completions.push(complete)
      })
    })
    const upstream = new Socket()
    const client = new Socket()
    const server = {
      handleUpgrade: (
        _request: IncomingMessage,
        _socket: Socket,
        _head: Buffer,
        done: (accepted: typeof webSocket) => void
      ) => done(webSocket)
    }
    const pause = vi.spyOn(upstream, "pause")
    const resume = vi.spyOn(upstream, "resume")
    try {
      const config = { port: 5901, name: "Desktop" }
      spliceVNCSocket(
        config,
        new URL(`http://localhost/?displayId=${vncDisplayId(config)}`),
        new IncomingMessage(client),
        client,
        Buffer.alloc(0),
        server,
        () => upstream,
        new VNCControlArbiter(),
        4
      )
      resume.mockClear()

      const first = Buffer.from([1])
      upstream.emit("data", first)
      expect(upstream.isPaused()).toBe(false)
      expect(pause).not.toHaveBeenCalled()

      const second = Buffer.alloc(queued - first.length, 2)
      upstream.emit("data", second)
      expect(upstream.isPaused()).toBe(true)
      expect(pause).toHaveBeenCalledOnce()
      expect(webSocket.send.mock.calls.map(([chunk, options]) => [chunk, options])).toEqual([
        [first, { binary: true }],
        [second, { binary: true }]
      ])

      webSocket.bufferedAmount = 4
      completions.shift()!()
      expect(upstream.isPaused()).toBe(true)
      expect(resume).not.toHaveBeenCalled()

      webSocket.bufferedAmount = 3
      completions.shift()!()
      expect(upstream.isPaused()).toBe(false)
      expect(resume).toHaveBeenCalledOnce()

      webSocket.bufferedAmount = 0
      upstream.emit("data", first)
      webSocket.bufferedAmount = 0
      completions.shift()!()
      expect(upstream.isPaused()).toBe(false)
      expect(pause).toHaveBeenCalledOnce()
      expect(resume).toHaveBeenCalledOnce()
      expect(completions).toHaveLength(0)
    } finally {
      pause.mockRestore()
      resume.mockRestore()
      upstream.destroy()
      client.destroy()
    }
  }
)
