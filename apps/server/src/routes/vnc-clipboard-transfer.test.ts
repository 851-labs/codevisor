import { describe, expect, it } from "vitest"

import {
  archiveClipboard,
  type ClipboardContent,
  type ClipboardMessage,
  ClipboardTransfer,
  MAXIMUM_CONTENT_BYTES,
  parseClipboardMessage,
  RICH_CHUNK_BYTES,
  TEXT_TYPE,
  unarchiveClipboard
} from "./vnc-clipboard.js"

const text = (value: string): ClipboardContent => [[{ type: TEXT_TYPE, data: Buffer.from(value) }]]

const deferred = <T>() => Promise.withResolvers<T>()

const refused = (id: string) => ({
  result: { id, error: "Clipboard transfer was not requested or is too large." }
})

const fixture = (options: { authorized?: boolean; sendable?: number } = {}) => {
  const sent: ClipboardMessage[] = []
  const finished: Array<string | undefined> = []
  const reads: Array<ReturnType<typeof deferred<ClipboardContent>>> = []
  const writes: Array<ReturnType<typeof deferred<undefined>>> = []
  const written: ClipboardContent[] = []
  let time = 0
  let authorized = options.authorized ?? true
  let sendable = options.sendable ?? Infinity
  const transfer = new ClipboardTransfer({
    send: (message) => {
      if (sendable <= 0) return false
      sendable -= 1
      sent.push(message)
      return true
    },
    now: () => time,
    canReceiveUnsolicited: () => authorized,
    read: () => {
      const read = deferred<ClipboardContent>()
      reads.push(read)
      return read.promise
    },
    write: (content) => {
      written.push(content)
      const write = deferred<undefined>()
      writes.push(write)
      return write.promise
    },
    onFinished: (error) => finished.push(error)
  })
  return {
    transfer,
    sent,
    finished,
    reads,
    writes,
    written,
    advance: (milliseconds: number) => {
      time += milliseconds
    },
    setAuthorized: (value: boolean) => {
      authorized = value
    }
  }
}

const incoming = (
  archive: Buffer,
  id = "IN"
): [ClipboardMessage, ClipboardMessage, ClipboardMessage] => [
  { begin: { id, bytes: archive.length, richContent: true } },
  { chunk: { id, index: 0, data: archive.toString("base64") } },
  { end: { id } }
]

describe("clipboard messages", () => {
  it.each([
    [null],
    [{}],
    [{ read: { id: "A" }, end: { id: "A" } }],
    [{ read: 1 }],
    [{ read: { id: "" } }],
    [{ read: { id: "x".repeat(65) } }],
    [{ begin: { id: "A", bytes: -1 } }],
    [{ begin: { id: "A", bytes: 1, richContent: "yes" } }],
    [{ chunk: { id: "A", index: 0 } }],
    [{ ack: { id: "A", nextIndex: 1.5 } }],
    [{ result: { id: "A", error: 7 } }],
    [{ teleport: { id: "A" } }]
  ])("refuses %j", (value) => {
    expect(parseClipboardMessage(value)).toBeUndefined()
  })

  it("reads every message the Mac sends", () => {
    for (const message of [
      { read: { id: "A" } },
      { end: { id: "A" } },
      { cancel: { id: "A" } },
      { begin: { id: "A", bytes: 3 } },
      { begin: { id: "A", bytes: 3, richContent: true } },
      { chunk: { id: "A", index: 0, data: "AQID" } },
      { ack: { id: "A", nextIndex: 2 } },
      { result: { id: "A" } },
      { result: { id: "A", error: "busy" } }
    ])
      expect(parseClipboardMessage(message)).toEqual(message)
  })

  it("refuses archives with an empty or oversized type", () => {
    const archive = archiveClipboard(text("hi"))
    const emptyType = Buffer.from(archive)
    emptyType.writeUInt32BE(0, 8)
    expect(unarchiveClipboard(emptyType)).toBeUndefined()
    const longType = archiveClipboard([[{ type: "x".repeat(257), data: Buffer.alloc(0) }]])
    expect(unarchiveClipboard(longType)).toBeUndefined()
  })
})

describe("clipboard transfer", () => {
  it("answers a read with the desktop's clipboard, or with why it couldn't", async () => {
    const f = fixture()
    f.transfer.receive({ read: { id: "R1" } })
    f.transfer.receive({ read: { id: "R2" } })
    expect(f.sent).toEqual([{ result: { id: "R2", error: "Clipboard is unavailable or busy." } }])
    f.reads[0]?.resolve(text("hi"))
    await f.reads[0]?.promise
    expect(f.sent.at(-1)).toMatchObject({ begin: { id: "R1", richContent: true } })

    const failing = fixture()
    failing.transfer.receive({ read: { id: "R3" } })
    failing.reads[0]?.reject("no owner")
    await failing.reads[0]?.promise.catch(() => undefined)
    expect(failing.sent).toEqual([{ result: { id: "R3", error: "no owner" } }])
  })

  it("drops a read that finishes after its transfer was cancelled", async () => {
    const f = fixture()
    f.transfer.receive({ read: { id: "R1" } })
    f.transfer.receive({ cancel: { id: "R1" } })
    f.transfer.receive({ read: { id: "R2" } })
    f.transfer.cancel()
    f.reads[0]?.resolve(text("late"))
    f.reads[1]?.reject(new Error("late"))
    await f.reads[0]?.promise
    await f.reads[1]?.promise.catch(() => undefined)
    expect(f.sent).toEqual([{ cancel: { id: "R2" } }])
    expect(f.finished).toEqual(["Clipboard transfer was cancelled.", undefined])
  })

  it("refuses transfers that weren't rich, authorized, small enough or expected", () => {
    const f = fixture()
    f.transfer.receive({ begin: { id: "T", bytes: 3 } })
    f.transfer.receive({ begin: { id: "B", bytes: MAXIMUM_CONTENT_BYTES + 1, richContent: true } })
    f.transfer.receive({ begin: { id: "OK", bytes: 4, richContent: true } })
    f.transfer.receive({ begin: { id: "BUSY", bytes: 4, richContent: true } })
    expect(f.sent).toEqual([
      refused("T"),
      refused("B"),
      { ack: { id: "OK", nextIndex: 0 } },
      refused("BUSY")
    ])
    const unauthorized = fixture({ authorized: false })
    unauthorized.transfer.receive({ begin: { id: "U", bytes: 4, richContent: true } })
    expect(unauthorized.sent).toEqual([refused("U")])
  })

  it("rejects bad chunks and incomplete or invalid data without writing", () => {
    const f = fixture()
    f.transfer.receive({ chunk: { id: "NONE", index: 0, data: "AQ==" } })
    f.transfer.receive({ begin: { id: "C", bytes: 2, richContent: true } })
    f.transfer.receive({ chunk: { id: "C", index: 1, data: "AQ==" } })
    expect(f.finished).toEqual(["Invalid clipboard chunk."])
    f.transfer.receive({ begin: { id: "D", bytes: 2, richContent: true } })
    f.transfer.receive({ cancel: { id: "D" } })
    expect(f.finished.at(-1)).toBe("Clipboard transfer was cancelled.")
    f.finished.splice(1)
    for (const [id, data] of [
      ["SHORT", Buffer.from([1])],
      ["JUNK", Buffer.from([1, 2])]
    ] as const) {
      f.transfer.receive({ begin: { id, bytes: 2, richContent: true } })
      f.transfer.receive({ chunk: { id, index: 0, data: data.toString("base64") } })
      f.transfer.receive({ end: { id: "OTHER" } })
      f.transfer.receive({ end: { id } })
    }
    expect(f.finished.slice(1)).toEqual([
      "Clipboard data was incomplete or not valid.",
      "Clipboard data was incomplete or not valid."
    ])
    expect(f.written).toEqual([])
  })

  it("won't write once control is lost, and reports a failed write", async () => {
    const lost = fixture()
    const archive = archiveClipboard(text("hi"))
    const [begin, chunk, end] = incoming(archive)
    lost.transfer.receive(begin)
    lost.transfer.receive(chunk)
    lost.setAuthorized(false)
    lost.transfer.receive(end)
    expect(lost.finished).toEqual(["Clipboard transfer is no longer authorized."])
    expect(lost.written).toEqual([])

    const f = fixture()
    for (const message of incoming(archive)) f.transfer.receive(message)
    f.writes[0]?.reject(new Error("xclip stopped"))
    await f.writes[0]?.promise.catch(() => undefined)
    expect(f.sent.at(-1)).toEqual({ result: { id: "IN", error: "xclip stopped" } })

    const unauthorized = fixture({ authorized: false })
    unauthorized.transfer.receive({ read: { id: "R" } })
    unauthorized.reads[0]?.resolve(text("x"))
    await unauthorized.reads[0]?.promise
    expect(unauthorized.sent.at(-1)).toMatchObject({ begin: { id: "R" } })
  })

  it("drops a write that finishes after its transfer was cancelled", async () => {
    const archive = archiveClipboard(text("hi"))
    for (const settle of ["resolve", "reject"] as const) {
      const f = fixture()
      for (const message of incoming(archive)) f.transfer.receive(message)
      f.transfer.receive({ cancel: { id: "IN" } })
      if (settle === "resolve") f.writes[0]?.resolve(undefined)
      else f.writes[0]?.reject(new Error("late"))
      await f.writes[0]?.promise.catch(() => undefined)
      expect(f.sent.some((message) => "result" in message)).toBe(false)
    }
  })

  it("sends in a window, ends after the last acknowledgment and checks every reply", () => {
    const f = fixture()
    const content: ClipboardContent = [
      [{ type: "public.png", data: Buffer.alloc(RICH_CHUNK_BYTES * 2) }]
    ]
    f.transfer.sendContent(content)
    f.transfer.sendContent(text("ignored while busy"))
    const begin = f.sent[0]
    const id = begin !== undefined && "begin" in begin ? begin.begin.id : ""
    f.transfer.receive({ ack: { id: "OTHER", nextIndex: 0 } })
    f.transfer.receive({ result: { id: "OTHER" } })
    f.transfer.receive({ cancel: { id: "OTHER" } })
    f.transfer.receive({ ack: { id, nextIndex: 0 } })
    expect(f.sent.filter((message) => "chunk" in message)).toHaveLength(3)
    for (const nextIndex of [1, 2, 3]) f.transfer.receive({ ack: { id, nextIndex } })
    expect(f.sent.at(-1)).toEqual({ end: { id } })
    f.transfer.receive({ ack: { id, nextIndex: 4 } })
    f.transfer.receive({ result: { id } })
    expect(f.finished).toEqual([undefined])

    f.transfer.sendContent(text("again"))
    const second = f.sent.at(-1)
    const secondId = second !== undefined && "begin" in second ? second.begin.id : ""
    f.transfer.receive({ ack: { id: secondId, nextIndex: 5 } })
    expect(f.finished.at(-1)).toBe("Invalid clipboard acknowledgment.")
    f.transfer.sendContent(text("early"))
    const third = f.sent.at(-1)
    const thirdId = third !== undefined && "begin" in third ? third.begin.id : ""
    f.transfer.receive({ result: { id: thirdId } })
    expect(f.finished.at(-1)).toBe("Invalid clipboard completion.")
    f.transfer.sendContent(text("refused"))
    const fourth = f.sent.at(-1)
    const fourthId = fourth !== undefined && "begin" in fourth ? fourth.begin.id : ""
    f.transfer.receive({ result: { id: fourthId, error: "The local clipboard changed." } })
    expect(f.finished.at(-1)).toBe("The local clipboard changed.")
    f.transfer.sendContent(text("cancelled"))
    const fifth = f.sent.at(-1)
    f.transfer.receive({
      cancel: { id: fifth !== undefined && "begin" in fifth ? fifth.begin.id : "" }
    })
    expect(f.finished.at(-1)).toBe("Clipboard transfer was cancelled.")
  })

  it("stops when the channel goes away mid-window", () => {
    const f = fixture({ sendable: 3 })
    f.transfer.sendContent([[{ type: "public.png", data: Buffer.alloc(RICH_CHUNK_BYTES * 3) }]])
    const begin = f.sent[0]
    const id = begin !== undefined && "begin" in begin ? begin.begin.id : ""
    f.transfer.receive({ ack: { id, nextIndex: 0 } })
    expect(f.finished).toEqual(["The clipboard channel is unavailable. Reconnect and try again."])
    expect(f.transfer.busy).toBe(false)
  })

  it("refuses to send more than 32 MB and times out only when idle", () => {
    const f = fixture()
    f.transfer.cancel()
    f.transfer.tick()
    f.transfer.sendContent([[{ type: "public.png", data: Buffer.alloc(MAXIMUM_CONTENT_BYTES) }]])
    expect(f.finished).toEqual(["The clipboard must be 32 MB or smaller."])
    f.transfer.sendContent(text("hi"))
    f.advance(9_999)
    f.transfer.tick()
    expect(f.transfer.busy).toBe(true)
    f.advance(1)
    f.transfer.tick()
    expect(f.finished.at(-1)).toBe("Clipboard transfer timed out. Try again.")
  })
})
