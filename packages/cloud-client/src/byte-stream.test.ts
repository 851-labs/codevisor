import { describe, expect, it } from "vitest"
import {
  BYTE_STREAM_INITIAL_CREDIT_BYTES,
  BYTE_STREAM_MAX_CHUNK_BYTES,
  byteStreamSealedBytes,
  codevisorLoopbackParams,
  parseByteStreamChannelParams
} from "./byte-stream.js"

describe("byte stream protocol", () => {
  it("accepts only the fixed Codevisor loopback service", () => {
    expect(parseByteStreamChannelParams(codevisorLoopbackParams())).toEqual({
      service: "codevisor-loopback",
      version: 1
    })
    expect(
      parseByteStreamChannelParams({ service: "codevisor-loopback", version: 2 })
    ).toBeUndefined()
    expect(parseByteStreamChannelParams({ service: "tcp", version: 1 })).toBeUndefined()
    expect(parseByteStreamChannelParams({ host: "example.com", port: 443 })).toBeUndefined()
    expect(parseByteStreamChannelParams("codevisor-loopback")).toBeUndefined()
    expect(parseByteStreamChannelParams(null)).toBeUndefined()
  })

  it("calculates ciphertext credit exactly", () => {
    expect(byteStreamSealedBytes(0)).toBe(22)
    expect(byteStreamSealedBytes(1)).toBe(23)
    expect(byteStreamSealedBytes(BYTE_STREAM_MAX_CHUNK_BYTES)).toBe(87_403)
    expect(BYTE_STREAM_INITIAL_CREDIT_BYTES).toBeGreaterThan(
      byteStreamSealedBytes(BYTE_STREAM_MAX_CHUNK_BYTES)
    )
    expect(() => byteStreamSealedBytes(-1)).toThrow()
  })
})
