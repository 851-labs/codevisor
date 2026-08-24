import { describe, expect, it } from "vitest"
import {
  ChannelCipher,
  KEY_LENGTH,
  acceptChannel,
  fromBase64Url,
  generateDeviceKeyPair,
  openChannel,
  openJson,
  sealJson,
  toBase64Url
} from "./index.js"

const setup = () => {
  const app = generateDeviceKeyPair()
  const machine = generateDeviceKeyPair()
  const opened = openChannel(app.secretKey, machine.publicKey)
  const responder = acceptChannel(machine.secretKey, app.publicKey, opened.ephemeralPublicKey)
  return { app, machine, opened, responder }
}

describe("base64url", () => {
  it("round-trips arbitrary byte lengths (all padding cases)", () => {
    for (const length of [0, 1, 2, 3, 4, 31, 32, 33]) {
      const bytes = new Uint8Array(Array.from({ length }, (_, index) => (index * 37) % 256))
      const encoded = toBase64Url(bytes)
      expect(encoded).not.toMatch(/[+/=]/)
      expect(fromBase64Url(encoded)).toEqual(bytes)
    }
  })

  it("rejects non-base64url input", () => {
    expect(() => fromBase64Url("not valid!")).toThrow("invalid base64url input")
  })
})

describe("generateDeviceKeyPair", () => {
  it("produces distinct 32-byte X25519 keys", () => {
    const first = generateDeviceKeyPair()
    const second = generateDeviceKeyPair()
    expect(fromBase64Url(first.publicKey)).toHaveLength(KEY_LENGTH)
    expect(fromBase64Url(first.secretKey)).toHaveLength(KEY_LENGTH)
    expect(first.publicKey).not.toBe(second.publicKey)
    expect(first.secretKey).not.toBe(second.secretKey)
  })
})

describe("channel encryption", () => {
  it("round-trips frames in both directions", () => {
    const { opened, responder } = setup()
    const request = new TextEncoder().encode("resize 120x40")
    const sealedRequest = opened.cipher.seal("ch-1", "opener-to-responder", 0, request)
    expect(responder.open("ch-1", "opener-to-responder", 0, sealedRequest)).toEqual(request)

    const reply = new Uint8Array([1, 2, 3, 255])
    const sealedReply = responder.seal("ch-1", "responder-to-opener", 0, reply)
    expect(opened.cipher.open("ch-1", "responder-to-opener", 0, sealedReply)).toEqual(reply)
  })

  it("derives nonces deterministically from direction and seq", () => {
    const { opened } = setup()
    const payload = new Uint8Array([9])
    // Same (direction, seq) → same box (callers must never reuse a seq for
    // different payloads); different seq/direction → different boxes.
    const first = opened.cipher.seal("ch-1", "opener-to-responder", 0, payload)
    const repeat = opened.cipher.seal("ch-1", "opener-to-responder", 0, payload)
    const nextSeq = opened.cipher.seal("ch-1", "opener-to-responder", 1, payload)
    const otherDirection = opened.cipher.seal("ch-1", "responder-to-opener", 0, payload)
    expect(repeat).toEqual(first)
    expect(nextSeq).not.toEqual(first)
    expect(otherDirection).not.toEqual(first)
  })

  it("rejects invalid sequence numbers", () => {
    const { opened } = setup()
    expect(() => opened.cipher.seal("ch-1", "opener-to-responder", -1, new Uint8Array())).toThrow(
      "invalid seq"
    )
    expect(() =>
      opened.cipher.seal(
        "ch-1",
        "opener-to-responder",
        Number.MAX_SAFE_INTEGER + 2,
        new Uint8Array()
      )
    ).toThrow("invalid seq")
  })

  it("binds ciphertext to channel, direction, and seq", () => {
    const { opened, responder } = setup()
    const sealed = opened.cipher.seal("ch-1", "opener-to-responder", 4, new Uint8Array([7]))
    expect(() => responder.open("ch-2", "opener-to-responder", 4, sealed)).toThrow()
    expect(() => responder.open("ch-1", "responder-to-opener", 4, sealed)).toThrow()
    expect(() => responder.open("ch-1", "opener-to-responder", 5, sealed)).toThrow()
    expect(responder.open("ch-1", "opener-to-responder", 4, sealed)).toEqual(new Uint8Array([7]))
  })

  it("authenticates the opener's static key (dual DH)", () => {
    const { machine, opened } = setup()
    const impostor = generateDeviceKeyPair()
    // Machine believes the peer is `impostor`, but frames were sealed with the
    // real app's static key — decryption must fail.
    const responder = acceptChannel(
      machine.secretKey,
      impostor.publicKey,
      opened.ephemeralPublicKey
    )
    const sealed = opened.cipher.seal("ch-1", "opener-to-responder", 0, new Uint8Array([1]))
    expect(() => responder.open("ch-1", "opener-to-responder", 0, sealed)).toThrow()
  })

  it("derives distinct keys per channel open", () => {
    const app = generateDeviceKeyPair()
    const machine = generateDeviceKeyPair()
    const first = openChannel(app.secretKey, machine.publicKey)
    const second = openChannel(app.secretKey, machine.publicKey)
    expect(first.ephemeralPublicKey).not.toBe(second.ephemeralPublicKey)
    const sealed = first.cipher.seal("ch-1", "opener-to-responder", 0, new Uint8Array([1]))
    expect(() => second.cipher.open("ch-1", "opener-to-responder", 0, sealed)).toThrow()
  })

  it("rejects malformed boxes and keys", () => {
    const { responder } = setup()
    expect(() => responder.open("ch-1", "opener-to-responder", 0, new Uint8Array(4))).toThrow()
    expect(() => new ChannelCipher(new Uint8Array(16))).toThrow("invalid channel key length")
  })
})

describe("json helpers", () => {
  it("round-trips structured payloads", () => {
    const { opened, responder } = setup()
    const payload = { channelType: "terminal", params: { terminalId: "t-1", sinceSeq: 42 } }
    const sealed = sealJson(opened.cipher, "ch-9", "opener-to-responder", 0, payload)
    expect(openJson(responder, "ch-9", "opener-to-responder", 0, sealed)).toEqual(payload)
  })
})
