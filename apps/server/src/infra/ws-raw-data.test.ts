import { describe, expect, it } from "vitest"

import { rawDataBytes } from "./ws-raw-data.js"

describe("rawDataBytes", () => {
  it("joins a fragmented message into one buffer", () => {
    expect(rawDataBytes([Buffer.from("hel"), Buffer.from("lo")]).toString()).toBe("hello")
  })

  it("copies an ArrayBuffer message into a buffer", () => {
    const bytes = rawDataBytes(new Uint8Array([104, 105]).buffer)
    expect(Buffer.isBuffer(bytes)).toBe(true)
    expect(bytes.toString()).toBe("hi")
  })

  it("passes a buffer message through unchanged", () => {
    const message = Buffer.from("same")
    expect(rawDataBytes(message)).toBe(message)
  })
})
