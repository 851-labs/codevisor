import { describe, expect, it } from "vitest"

import { SizeArbiter } from "./size-arbiter.js"

describe("SizeArbiter", () => {
  it("sizes the PTY for the client being used, not the one merely watching", () => {
    const arbiter = new SizeArbiter({ cols: 80, rows: 24 })
    // The first client to show the terminal sizes it.
    expect(arbiter.resize("mac", { cols: 200, rows: 50 })).toEqual({ cols: 200, rows: 50 })
    // Another client showing it doesn't take the size.
    expect(arbiter.resize("phone", { cols: 60, rows: 30 })).toBeUndefined()
    // Using it does, and using the Mac takes it back.
    expect(arbiter.claim("phone")).toEqual({ cols: 60, rows: 30 })
    expect(arbiter.claim("phone")).toBeUndefined()
    expect(arbiter.claim("mac")).toEqual({ cols: 200, rows: 50 })
    // The owner's own resizes apply; a watcher's are only remembered.
    expect(arbiter.resize("mac", { cols: 190, rows: 50 })).toEqual({ cols: 190, rows: 50 })
    expect(arbiter.resize("phone", { cols: 61, rows: 30 })).toBeUndefined()
    // A client not showing the terminal can't claim it by typing.
    expect(arbiter.claim("cli")).toBeUndefined()
    expect(arbiter.size).toEqual({ cols: 190, rows: 50 })
  })

  it("hands the size to the last active client still showing the terminal", () => {
    const arbiter = new SizeArbiter({ cols: 80, rows: 24 })
    arbiter.resize("mac", { cols: 200, rows: 50 })
    arbiter.resize("tablet", { cols: 120, rows: 40 })
    arbiter.resize("phone", { cols: 60, rows: 30 })
    arbiter.claim("tablet")
    arbiter.claim("phone")
    // A watcher leaving changes nothing.
    expect(arbiter.hide("mac")).toBeUndefined()
    expect(arbiter.hide("mac")).toBeUndefined()
    // The owner leaving hands the size to the last one active.
    expect(arbiter.release("phone")).toEqual({ cols: 120, rows: 40 })
    // With nobody showing it, the PTY keeps its last size.
    expect(arbiter.hide("tablet")).toBeUndefined()
    expect(arbiter.size).toEqual({ cols: 120, rows: 40 })
    // The next client to show it takes it.
    expect(arbiter.resize("mac", { cols: 200, rows: 50 })).toEqual({ cols: 200, rows: 50 })
  })
})
