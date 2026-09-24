import { describe, expect, it } from "vitest"

import { VNCControlArbiter, vncControlArbiter } from "./vnc-control.js"

const viewer = (arbiter: VNCControlArbiter) => {
  const received: unknown[] = []
  const id = arbiter.join((text) => received.push(JSON.parse(text)))
  return { id, received }
}

describe("VNC control lease (851-2338)", () => {
  it("hands control to the last requester and tells the previous controller who took it", () => {
    const arbiter = new VNCControlArbiter()
    const a = viewer(arbiter)
    const b = viewer(arbiter)
    arbiter.receive(a.id, JSON.stringify({ type: "request", name: "Studio" }))
    expect(a.received).toEqual([{ type: "granted" }])
    expect(arbiter.mayControl(a.id)).toBe(true)
    expect(arbiter.mayControl(b.id)).toBe(true) // b never spoke the lease: not arbitrated yet
    arbiter.receive(b.id, JSON.stringify({ type: "request", name: "  Laptop  " }))
    expect(a.received.at(-1)).toEqual({ type: "revoked", by: "Laptop" })
    expect(b.received).toEqual([{ type: "granted" }])
    expect(arbiter.mayControl(a.id)).toBe(false)
    expect(arbiter.mayControl(b.id)).toBe(true)
    // Requesting again while in control just grants again.
    arbiter.receive(b.id, JSON.stringify({ type: "request" }))
    expect(b.received).toEqual([{ type: "granted" }, { type: "granted" }])
    expect(a.received).toHaveLength(2)
  })

  it("names an anonymous taker, and frees control on release or leaving", () => {
    const arbiter = new VNCControlArbiter()
    const a = viewer(arbiter)
    const b = viewer(arbiter)
    arbiter.receive(a.id, JSON.stringify({ type: "request" }))
    arbiter.receive(b.id, JSON.stringify({ type: "request", name: " " }))
    expect(a.received.at(-1)).toEqual({ type: "revoked", by: "Another viewer" })
    arbiter.receive(a.id, JSON.stringify({ type: "release" })) // not the controller: no effect
    expect(arbiter.mayControl(b.id)).toBe(true)
    arbiter.receive(b.id, JSON.stringify({ type: "release" }))
    expect(arbiter.mayControl(b.id)).toBe(false)
    arbiter.receive(a.id, JSON.stringify({ type: "request" }))
    arbiter.leave(a.id)
    expect(arbiter.mayControl(a.id)).toBe(false)
    arbiter.receive(b.id, JSON.stringify({ type: "request" }))
    expect(arbiter.mayControl(b.id)).toBe(true)
  })

  it("sizes the desktop for the controller, else the most recent viewer", () => {
    const arbiter = new VNCControlArbiter()
    const a = viewer(arbiter)
    const b = viewer(arbiter)
    const legacy = viewer(arbiter)
    for (const id of [a.id, b.id]) arbiter.receive(id, JSON.stringify({ type: "hello" }))
    expect(arbiter.mayResize(legacy.id)).toBe(true) // an older app isn't arbitrated
    expect(arbiter.mayResize(a.id)).toBe(false)
    arbiter.leave(legacy.id)
    expect(arbiter.mayResize(b.id)).toBe(true) // now the most recent
    arbiter.receive(a.id, JSON.stringify({ type: "request" }))
    expect(arbiter.mayResize(a.id)).toBe(true)
    expect(arbiter.mayResize(b.id)).toBe(false)
    arbiter.leave(b.id)
    arbiter.leave(a.id)
    expect(arbiter.mayResize(a.id)).toBe(false)
    expect(arbiter.mayControl(a.id)).toBe(false)
  })

  it("ignores malformed messages and unknown viewers", () => {
    const arbiter = new VNCControlArbiter()
    const a = viewer(arbiter)
    arbiter.receive(a.id, "{")
    arbiter.receive(a.id, "7")
    arbiter.receive(999, JSON.stringify({ type: "request" }))
    expect(a.received).toEqual([])
    expect(arbiter.mayControl(a.id)).toBe(true) // still not arbitrated: nothing it sent was a lease message
  })

  it("keeps one arbiter per desktop", () => {
    expect(vncControlArbiter(41901)).toBe(vncControlArbiter(41901))
    expect(vncControlArbiter(41901)).not.toBe(vncControlArbiter(41902))
  })
})
