import { describe, expect, it } from "vitest"

import { type RFBClientMessageKind, RFBClientStreamFilter } from "./rfb-client-filter.js"

const version = Buffer.from("RFB 003.008\n", "latin1")
const handshake = (security = 1): Buffer =>
  Buffer.concat([
    version,
    Buffer.from([security]),
    ...(security === 2 ? [Buffer.alloc(16, 7)] : []),
    Buffer.from([1])
  ])

/// Every client message the viewer sends, in wire form.
const messages = {
  setPixelFormat: Buffer.concat([Buffer.from([0]), Buffer.alloc(19, 1)]),
  setEncodings: Buffer.from([2, 0, 0, 2, 0, 0, 0, 7, 0xff, 0xff, 0xff, 0x21]),
  updateRequest: Buffer.from([3, 1, 0, 0, 0, 0, 0, 64, 0, 48]),
  key: Buffer.from([4, 1, 0, 0, 0, 0, 0, 0x61]),
  pointer: Buffer.from([5, 1, 0, 10, 0, 20]),
  cutText: Buffer.concat([Buffer.from([6, 0, 0, 0, 0, 0, 0, 3]), Buffer.from("abc")]),
  extendedClipboard: Buffer.concat([
    Buffer.from([6, 0, 0, 0, 0xff, 0xff, 0xff, 0xfc]),
    Buffer.alloc(4, 9)
  ]),
  continuous: Buffer.from([150, 1, 0, 0, 0, 0, 0, 64, 0, 48]),
  fence: Buffer.from([248, 0, 0, 0, 0x80, 0, 0, 1, 2, 0xaa, 0xbb]),
  setDesktopSize: Buffer.concat([Buffer.from([251, 0, 4, 0, 3, 0, 1, 0]), Buffer.alloc(16, 5)])
}

const allExcept =
  (...denied: RFBClientMessageKind[]) =>
  (kind: RFBClientMessageKind) =>
    !denied.includes(kind)

describe("RFB client stream filter (851-2338)", () => {
  it("drops exactly the refused messages, keeping every other byte in order", () => {
    const filter = new RFBClientStreamFilter()
    const out = filter.push(
      Buffer.concat([handshake(), ...Object.values(messages)]),
      allExcept("input", "clipboard", "resize")
    )
    expect(out).toEqual(
      Buffer.concat([
        handshake(),
        messages.setPixelFormat,
        messages.setEncodings,
        messages.updateRequest,
        messages.continuous,
        messages.fence
      ])
    )
  })

  it("follows messages split across pushes, one byte at a time", () => {
    const filter = new RFBClientStreamFilter()
    const stream = Buffer.concat([
      handshake(2),
      messages.key,
      messages.setDesktopSize,
      messages.pointer
    ])
    const out: Buffer[] = []
    for (const byte of stream) out.push(filter.push(Buffer.from([byte]), allExcept("resize")))
    expect(Buffer.concat(out)).toEqual(
      Buffer.concat([handshake(2), messages.key, messages.pointer])
    )
  })

  it("waits for every message's length and body, one byte at a time", () => {
    const filter = new RFBClientStreamFilter()
    const all = Object.values(messages)
    const stream = Buffer.concat([handshake(), ...all])
    const out: Buffer[] = []
    for (const byte of stream) out.push(filter.push(Buffer.from([byte]), () => true))
    expect(Buffer.concat(out)).toEqual(stream)
  })

  it("forwards handshake bytes as they arrive, before a unit is complete", () => {
    const filter = new RFBClientStreamFilter()
    expect(filter.push(Buffer.from("RFB"), () => false)).toEqual(Buffer.from("RFB"))
  })

  it("passes everything through what it can't follow", () => {
    const deny = () => false
    const oldVersion = new RFBClientStreamFilter()
    const old = Buffer.concat([Buffer.from("RFB 003.003\n", "latin1"), messages.key])
    expect(oldVersion.push(old, deny)).toEqual(old)
    expect(oldVersion.push(messages.pointer, deny)).toEqual(messages.pointer)
    const otherSecurity = new RFBClientStreamFilter()
    const tls = Buffer.concat([version, Buffer.from([18]), messages.key])
    expect(otherSecurity.push(tls, deny)).toEqual(tls)
    const unknownMessage = new RFBClientStreamFilter()
    unknownMessage.push(handshake(), deny)
    const tail = Buffer.concat([Buffer.from([200, 1, 2]), messages.key])
    expect(unknownMessage.push(Buffer.concat([messages.key, tail]), deny)).toEqual(tail)
  })
})
