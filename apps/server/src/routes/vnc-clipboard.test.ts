import { describe, expect, it, vi } from "vitest"

import {
  type ClipboardClock,
  type DesktopClipboard,
  systemClipboardClock,
  VNCClipboardBridge
} from "./vnc-clipboard-bridge.js"
import {
  archiveClipboard,
  type ClipboardContent,
  ClipboardTransfer,
  isRecord,
  parseClipboardMessage,
  RICH_WINDOW,
  TEXT_TYPE,
  unarchiveClipboard
} from "./vnc-clipboard.js"

const SWIFT_ARCHIVE =
  "00000002000000020000000a7075626c69632e706e6700000003010203000000167075626c69632e757466382d706c61696e2d74657874000000026869000000010000000b7075626c69632e68746d6c000000033c623e"

const sample: ClipboardContent = [
  [
    { type: "public.png", data: Buffer.from([1, 2, 3]) },
    { type: TEXT_TYPE, data: Buffer.from("hi") }
  ],
  [{ type: "public.html", data: Buffer.from("<b>") }]
]

describe("clipboard archive", () => {
  it("matches the bytes the Mac writes and reads", () => {
    expect(archiveClipboard(sample).toString("hex")).toBe(SWIFT_ARCHIVE)
    expect(unarchiveClipboard(Buffer.from(SWIFT_ARCHIVE, "hex"))).toEqual(sample)
  })

  it("refuses empty, truncated or padded archives", () => {
    const archive = Buffer.from(SWIFT_ARCHIVE, "hex")
    expect(unarchiveClipboard(Buffer.alloc(4))).toBeUndefined()
    expect(unarchiveClipboard(archive.subarray(0, archive.length - 1))).toBeUndefined()
    expect(unarchiveClipboard(Buffer.concat([archive, Buffer.from([0])]))).toBeUndefined()
  })
})

class FakeClock implements ClipboardClock {
  time = 0
  private timers: Array<{ at: number; run: () => void; every?: number }> = []
  now = () => this.time
  setTimeout = (run: () => void, milliseconds: number) => this.schedule(run, milliseconds)
  setInterval = (run: () => void, milliseconds: number) =>
    this.schedule(run, milliseconds, milliseconds)
  advance(milliseconds: number): void {
    this.time += milliseconds
    for (const timer of this.timers.filter((due) => due.at <= this.time)) {
      if (timer.every === undefined) this.timers.splice(this.timers.indexOf(timer), 1)
      else timer.at += timer.every
      timer.run()
    }
  }
  private schedule(run: () => void, milliseconds: number, every?: number) {
    const timer = { at: this.time + milliseconds, run, ...(every === undefined ? {} : { every }) }
    this.timers.push(timer)
    return () => {
      const index = this.timers.indexOf(timer)
      if (index >= 0) this.timers.splice(index, 1)
    }
  }
}

class FakeDesktop implements DesktopClipboard {
  content: ClipboardContent = [[{ type: TEXT_TYPE, data: Buffer.from("desktop") }]]
  writes: ClipboardContent[] = []
  changed: (() => void) | undefined
  pending: Array<Promise<unknown>> = []
  watching = false
  watch = (changed: () => void) => {
    this.changed = changed
    this.watching = true
    return Promise.resolve(() => {
      this.watching = false
    })
  }
  reads = 0
  nextRead: Promise<ClipboardContent> | undefined
  read = () => {
    this.reads += 1
    const read = this.nextRead ?? Promise.resolve(this.content)
    this.nextRead = undefined
    return this.track(read)
  }
  write = (content: ClipboardContent) => {
    this.writes.push(content)
    this.content = content
    return this.track(Promise.resolve(content))
  }
  copy(content: ClipboardContent): void {
    this.content = content
    this.changed?.()
  }
  private track<T>(promise: Promise<T>): Promise<T> {
    this.pending.push(promise)
    return promise
  }
}

const harness = async (options: { controlling?: boolean } = {}) => {
  const clock = new FakeClock()
  const desktop = new FakeDesktop()
  const toViewer: Array<Record<string, unknown>> = []
  const toBridge: string[] = []
  let controlling = options.controlling ?? true
  const viewerResults: Array<string | undefined> = []
  const viewerContents: ClipboardContent[] = []
  const bridge = new VNCClipboardBridge(
    desktop,
    (text) => {
      const frame: unknown = JSON.parse(text)
      if (isRecord(frame)) toViewer.push(frame)
    },
    () => controlling,
    clock
  )
  const viewer = new ClipboardTransfer({
    send: (message) => {
      toBridge.push(JSON.stringify({ type: "clipboard", version: 1, message }))
      return true
    },
    now: clock.now,
    canReceiveUnsolicited: () => true,
    read: () => Promise.resolve(desktop.content),
    write: (content) => {
      viewerContents.push(content)
      return Promise.resolve()
    },
    onFinished: (error) => viewerResults.push(error)
  })
  await bridge.start()
  const announcement = toViewer.shift()
  let maximumInFlight = 0
  const drain = async () => {
    for (;;) {
      maximumInFlight = Math.max(
        maximumInFlight,
        toViewer.filter(hasChunk).length,
        toBridge.filter((frame) => hasChunk(JSON.parse(frame) as unknown)).length
      )
      const frame = toBridge.shift()
      if (frame !== undefined) {
        expect(bridge.receive(frame)).toBe(true)
        continue
      }
      const next = toViewer.shift()
      if (next !== undefined) {
        const message = parseClipboardMessage(next.message)
        if (message !== undefined) viewer.receive(message)
        continue
      }
      const pending = desktop.pending.splice(0)
      if (pending.length === 0) return
      await Promise.all(pending)
    }
  }
  return {
    clock,
    desktop,
    toViewer,
    bridge,
    viewer,
    announcement,
    viewerResults,
    viewerContents,
    drain,
    maximumInFlight: () => maximumInFlight,
    setControlling: (value: boolean) => {
      controlling = value
    },
    share: (sharing: boolean) =>
      bridge.receive(JSON.stringify({ type: "clipboard-viewer", sharing }))
  }
}

const clipboardFrame = (message: object) =>
  JSON.stringify({ type: "clipboard", version: 1, message })

const hasChunk = (frame: unknown): boolean =>
  isRecord(frame) && isRecord(frame.message) && "chunk" in frame.message

const image = (size: number, seed = 1): ClipboardContent => [
  [{ type: "public.png", data: Buffer.alloc(size, seed) }]
]

describe("VNC clipboard bridge", () => {
  it("announces itself and puts what the Mac copied on the desktop's clipboard", async () => {
    const h = await harness()
    expect(h.announcement).toEqual({ type: "clipboard-host", richContent: true })
    const content = image(500_000)
    h.viewer.sendContent(content)
    await h.drain()
    expect(h.desktop.writes).toEqual([content])
    expect(h.viewerResults).toEqual([undefined])
    expect(h.maximumInFlight()).toBe(RICH_WINDOW)
  })

  it("only the viewer in control may write the desktop's clipboard, but anyone may read it", async () => {
    const h = await harness({ controlling: false })
    h.viewer.sendContent(image(10))
    await h.drain()
    expect(h.desktop.writes).toEqual([])
    expect(h.viewerResults).toEqual(["Clipboard transfer was not requested or is too large."])

    h.bridge.receive(
      JSON.stringify({ type: "clipboard", version: 1, message: { read: { id: "GET" } } })
    )
    await h.drain()
    expect(h.viewerContents).toEqual([h.desktop.content])
  })

  it("shares a copy made on the desktop while sharing and in control, but never echoes its own write", async () => {
    const h = await harness()
    h.desktop.copy(image(10, 1))
    h.clock.advance(150)
    await h.drain()
    expect(h.viewerContents).toEqual([])

    h.share(true)
    h.viewer.sendContent(image(10, 2))
    await h.drain()
    h.desktop.changed?.()
    h.clock.advance(150)
    await h.drain()
    expect(h.viewerContents).toEqual([])

    const copied = image(600_000, 3)
    h.desktop.copy(copied)
    h.clock.advance(149)
    await h.drain()
    expect(h.viewerContents).toEqual([])
    h.clock.advance(1)
    await h.drain()
    expect(h.viewerContents).toEqual([copied])
    expect(h.maximumInFlight()).toBe(RICH_WINDOW)

    h.setControlling(false)
    h.desktop.copy(image(10, 4))
    h.clock.advance(150)
    await h.drain()
    expect(h.viewerContents).toEqual([copied])
  })

  it("cancels a transfer only after ten seconds without progress", async () => {
    const h = await harness()
    const cancelled = { type: "clipboard", version: 1, message: { cancel: { id: "SLOW" } } }
    h.bridge.receive(clipboardFrame({ begin: { id: "SLOW", bytes: 4, richContent: true } }))
    h.clock.advance(9_000)
    h.bridge.receive(
      clipboardFrame({
        chunk: { id: "SLOW", index: 0, data: Buffer.from([1, 2]).toString("base64") }
      })
    )
    h.clock.advance(9_000)
    expect(h.toViewer).not.toContainEqual(cancelled)
    h.clock.advance(1_000)
    expect(h.toViewer).toContainEqual(cancelled)
    expect(h.desktop.writes).toEqual([])
  })

  it("ignores text that isn't a clipboard frame so the control lease still sees it", async () => {
    const h = await harness()
    expect(h.bridge.receive('{"type":"request","name":"Mac"}')).toBe(false)
    expect(h.bridge.receive("not json")).toBe(false)
    h.bridge.close()
    expect(h.desktop.watching).toBe(false)
    expect(h.bridge.receive('{"type":"clipboard-viewer","sharing":true}')).toBe(true)
  })

  it("coalesces a burst of change events into one read", async () => {
    const h = await harness()
    h.share(true)
    h.desktop.copy(image(10, 1))
    h.clock.advance(100)
    h.desktop.copy(image(10, 2))
    h.clock.advance(150)
    await h.drain()
    expect(h.desktop.reads).toBe(1)
    expect(h.viewerContents).toEqual([image(10, 2)])
  })

  it("shares a desktop copy made during a transfer once that transfer ends", async () => {
    const h = await harness()
    h.share(true)
    h.bridge.receive(clipboardFrame({ begin: { id: "X", bytes: 10, richContent: true } }))
    h.desktop.copy(image(10, 5))
    h.clock.advance(150)
    expect(h.desktop.reads).toBe(0)
    h.bridge.receive(clipboardFrame({ cancel: { id: "X" } }))
    await h.drain()
    expect(h.viewerContents).toEqual([image(10, 5)])
  })

  it("drops a desktop read that finishes after sharing stopped, a transfer began or it failed", async () => {
    const h = await harness()
    h.share(true)
    for (const interrupt of [
      () => h.share(false),
      () => h.bridge.receive(clipboardFrame({ begin: { id: "Y", bytes: 10, richContent: true } }))
    ]) {
      const read = Promise.withResolvers<ClipboardContent>()
      h.desktop.nextRead = read.promise
      h.share(true)
      h.desktop.copy(image(10, 6))
      h.clock.advance(150)
      interrupt()
      read.resolve(image(10, 6))
      await h.drain()
    }
    h.bridge.receive(clipboardFrame({ cancel: { id: "Y" } }))
    h.desktop.nextRead = Promise.reject(new Error("no owner"))
    h.desktop.copy(image(10, 7))
    h.clock.advance(150)
    await h.drain().catch(() => undefined)
    expect(h.viewerContents).toEqual([])
  })

  it("lets the viewer's copy win over a desktop copy still being sent", async () => {
    const h = await harness()
    h.share(true)
    h.desktop.copy(image(600_000, 8))
    h.clock.advance(150)
    await Promise.all(h.desktop.pending.splice(0))
    const begin = h.toViewer
      .map((frame) => parseClipboardMessage(frame.message))
      .find((message) => message !== undefined && "begin" in message)
    const id = begin !== undefined && "begin" in begin ? begin.begin.id : "missing"
    h.bridge.receive(clipboardFrame({ begin: { id: "MAC", bytes: 10, richContent: true } }))
    expect(h.toViewer.slice(-2).map((frame) => frame.message)).toEqual([
      { cancel: { id } },
      { ack: { id: "MAC", nextIndex: 0 } }
    ])
  })

  it("ignores frames that aren't for it or that it can't read", async () => {
    const h = await harness()
    expect(h.bridge.receive("3")).toBe(false)
    expect(h.bridge.receive('{"type":7}')).toBe(false)
    expect(h.bridge.receive('{"type":"clipboard-viewer","sharing":"yes"}')).toBe(true)
    expect(h.bridge.receive('{"type":"clipboard","version":2,"message":{"read":{"id":"A"}}}')).toBe(
      true
    )
    expect(h.bridge.receive('{"type":"clipboard","version":1,"message":{"read":{}}}')).toBe(true)
    h.share(true)
    h.share(true)
    expect(h.toViewer).toEqual([])
  })

  it("closing stops watching, cancels what's in flight and cancels a pending settle", async () => {
    const h = await harness()
    h.share(true)
    h.bridge.receive(clipboardFrame({ begin: { id: "Z", bytes: 10, richContent: true } }))
    h.toViewer.splice(0)
    h.desktop.copy(image(10, 9))
    h.bridge.close()
    h.bridge.close()
    h.clock.advance(1_000)
    expect(h.desktop.reads).toBe(0)
    expect(h.toViewer).toEqual([])
    expect(h.desktop.watching).toBe(false)
  })

  it("stops a watcher that becomes ready after the bridge closed", async () => {
    const ready = Promise.withResolvers<() => void>()
    let stopped = false
    const announced: string[] = []
    const bridge = new VNCClipboardBridge(
      {
        watch: () => ready.promise,
        read: () => Promise.resolve([]),
        write: (content) => Promise.resolve(content)
      },
      (text) => announced.push(text),
      () => true,
      new FakeClock()
    )
    const started = bridge.start()
    bridge.close()
    ready.resolve(() => {
      stopped = true
    })
    await started
    expect(stopped).toBe(true)
    expect(announced).toEqual([])
  })
})

describe("system clipboard clock", () => {
  it("runs and cancels timers", () => {
    vi.useFakeTimers()
    try {
      const runs: string[] = []
      const cancelTimeout = systemClipboardClock.setTimeout(() => runs.push("timeout"), 10)
      const cancelled = systemClipboardClock.setTimeout(() => runs.push("cancelled"), 10)
      cancelled()
      const cancelInterval = systemClipboardClock.setInterval(() => runs.push("tick"), 10)
      vi.advanceTimersByTime(20)
      cancelInterval()
      cancelTimeout()
      vi.advanceTimersByTime(20)
      expect(runs).toEqual(["timeout", "tick", "tick"])
      expect(systemClipboardClock.now()).toBeGreaterThanOrEqual(0)
    } finally {
      vi.useRealTimers()
    }
  })
})
