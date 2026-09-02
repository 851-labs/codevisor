import { generateDeviceKeyPair, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { deflateRawSync, inflateRawSync } from "node:zlib"
import type { IncomingChannel } from "./index.js"
import { describe, expect, it } from "vitest"
import {
  machineKeys,
  harness,
  activeTimeout,
  connect,
  openEcho
} from "./machine-connection-test-support.js"

describe("incoming channels", () => {
  it("accepts an open, decrypts params, and round-trips sealed data", () => {
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-1", { terminalId: "t1" })
    const channel = h.channels[0]!
    expect(channel.channelType).toBe("echo")
    expect(channel.params).toEqual({ terminalId: "t1" })

    const received: unknown[] = []
    channel.onData = (value) => received.push(value)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-1", seq: 1 } },
      sealJson(opened.cipher, "ch-1", "opener-to-responder", 1, { input: "ls\n" })
    )
    expect(received).toEqual([{ input: "ls\n" }])

    channel.send({ output: "file.txt\n" })
    channel.send({ output: "done\n" })
    const dataEnvelopes = socket.sentRelay.filter((envelope) => envelope.header.frame.t === "data")
    expect(dataEnvelopes.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1])
    expect(dataEnvelopes.every((envelope) => envelope.header.peerId === "peer-1")).toBe(true)
    expect(
      openJson(opened.cipher, "ch-1", "responder-to-opener", 0, dataEnvelopes[0]!.payload)
    ).toEqual({ output: "file.txt\n" })

    const credits: number[] = []
    channel.onCredit = (bytes) => credits.push(bytes)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-1", seq: 2, bytes: 4096 }
    })
    expect(credits).toEqual([4096])

    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-1", seq: 3, reason: "done" }
    })
    expect(closes).toEqual(["done"])
    // Every outbound operation after close is a no-op: still just the two data frames.
    channel.send({ late: true })
    expect(channel.sendBytes(new Uint8Array([1]))).toBeUndefined()
    channel.deferInboundCredit()
    channel.grantCredit(1)
    expect(socket.sentRelay).toHaveLength(2)
  })

  it("relays opaque bytes with explicit receive credit", () => {
    const channels: IncomingChannel[] = []
    const h = harness({
      handlers: {
        echo: (channel) => {
          channels.push(channel)
          channel.deferInboundCredit()
          channel.grantCredit(100)
        }
      }
    })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-bytes")
    const channel = channels[0]!
    const received: { bytes: number[]; cost: number }[] = []
    channel.onBytes = (bytes, cost) => received.push({ bytes: [...bytes], cost })

    const box = opened.cipher.seal(
      "ch-bytes",
      "opener-to-responder",
      1,
      new Uint8Array([0, 1, 255])
    )
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-bytes", seq: 1 } },
      box
    )
    expect(received).toEqual([{ bytes: [0, 1, 255], cost: box.byteLength }])

    const sentCost = channel.sendBytes(new Uint8Array([9, 8, 7]))
    const envelopes = socket.sentRelay
    expect(envelopes[0]!.header.frame).toEqual({
      t: "credit",
      channelId: "ch-bytes",
      seq: 0,
      bytes: 100
    })
    const response = envelopes[1]!
    expect(response.header.frame).toEqual({ t: "data", channelId: "ch-bytes", seq: 1 })
    // Ciphertext cost = plaintext + 16-byte tag, no encoding expansion.
    expect(sentCost).toBe(response.payload.byteLength)
    expect(sentCost).toBe(3 + 16)
    expect([...opened.cipher.open("ch-bytes", "responder-to-opener", 1, response.payload)]).toEqual(
      [9, 8, 7]
    )
  })

  it("closes a byte channel that exceeds its granted receive window", () => {
    const channels: IncomingChannel[] = []
    const h = harness({
      handlers: {
        echo: (channel) => {
          channels.push(channel)
          channel.deferInboundCredit()
          channel.grantCredit(1)
          channel.onBytes = () => undefined
        }
      }
    })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-overrun")
    const closes: string[] = []
    channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-overrun", seq: 1 } },
      opened.cipher.seal("ch-overrun", "opener-to-responder", 1, new Uint8Array([1]))
    )
    expect(closes).toEqual(["protocol-error"])
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "protocol-error" })
  })

  it("machine-side close notifies the peer once", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!
    channel.close("done")
    channel.close("done") // second close is a no-op
    expect(socket.closeFrames()).toHaveLength(1)
  })

  it("answers frames for unknown channels with a peer-disconnected close", () => {
    const h = harness()
    const socket = connect(h)

    // The app kept this channel alive across a machine reconnect: we never saw
    // its open, so its frames must be answered with a close — not dropped —
    // or the app waits forever on a channel we no longer know about.
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-lost", seq: 7, bytes: 1024 }
    })
    expect(socket.closeFrames()).toHaveLength(1)
    expect(socket.closeFrames()[0]!.channelId).toBe("ch-lost")
    expect(socket.closeFrames()[0]!.reason).toBe("peer-disconnected")

    // Data frames get the same treatment (the check precedes decryption).
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-lost-2", seq: 3 } },
      new Uint8Array([0, 0, 0, 0])
    )
    expect(socket.closeFrames()).toHaveLength(2)
    expect(socket.closeFrames()[1]!.channelId).toBe("ch-lost-2")
    expect(socket.closeFrames()[1]!.reason).toBe("peer-disconnected")

    // A close for an unknown channel is ignored — no close-for-close loops.
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-lost-3", seq: 0, reason: "done" }
    })
    expect(socket.closeFrames()).toHaveLength(2)
  })

  it("refuses malformed opens", () => {
    const h = harness({
      handlers: { echo: () => undefined }
    })
    const socket = connect(h)
    const appKeys = generateDeviceKeyPair()
    const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
    const sealedOpen = (channelType: unknown, channelId: string) =>
      sealJson(opened.cipher, channelId, "opener-to-responder", 0, { channelType })

    // Open relayed without the peer's public key.
    socket.receiveRelay(
      {
        peerId: "p",
        frame: { t: "open", channelId: "c1", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealedOpen("echo", "c1")
    )
    expect(socket.lastClose().reason).toBe("protocol-error")

    // Undecryptable open payload.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c2", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      new Uint8Array([0, 0, 0])
    )
    expect(socket.lastClose().reason).toBe("crypto-error")

    // Non-string channelType.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c3", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealedOpen(42, "c3")
    )
    expect(socket.lastClose().reason).toBe("protocol-error")

    // Unknown channel type.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c4", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealJson(opened.cipher, "c4", "opener-to-responder", 0, { channelType: "screensaver" })
    )
    expect(socket.lastClose().reason).toBe("unsupported")
  })

  it("refuses duplicate channel ids per peer", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    openEcho(socket, "peer-1", "ch-1")
    expect(socket.closeFrames()).toHaveLength(1)
    expect(h.channels).toHaveLength(1)
  })

  it("kills channels on seq gaps and crypto failures", () => {
    const h = harness()
    const socket = connect(h)
    const first = openEcho(socket, "peer-1", "ch-gap")
    const gapCloses: string[] = []
    h.channels[0]!.onClosed = (reason) => gapCloses.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-gap", seq: 5 } }, // expected 1
      sealJson(first.opened.cipher, "ch-gap", "opener-to-responder", 5, {})
    )
    expect(gapCloses).toEqual(["protocol-error"])

    openEcho(socket, "peer-1", "ch-bad")
    const badCloses: string[] = []
    h.channels[1]!.onClosed = (reason) => badCloses.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-bad", seq: 1 } },
      new Uint8Array([0, 0, 0])
    )
    expect(badCloses).toEqual(["crypto-error"])
  })

  it("keeps the channel alive across interleaved credit frames (shared seq counter)", () => {
    // The keystroke-echo pattern: apps allocate credit seqs from the same
    // opener→responder counter as data seqs, so data(1), credit(2), data(3)
    // is a healthy channel — not a gap.
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-credit")
    const channel = h.channels[0]!
    const received: unknown[] = []
    const closes: string[] = []
    channel.onData = (value) => received.push(value)
    channel.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-credit", seq: 1 } },
      sealJson(opened.cipher, "ch-credit", "opener-to-responder", 1, { key: "a" })
    )
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit", seq: 2, bytes: 64 }
    })
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-credit", seq: 3 } },
      sealJson(opened.cipher, "ch-credit", "opener-to-responder", 3, { key: "b" })
    )
    expect(received).toEqual([{ key: "a" }, { key: "b" }])
    expect(closes).toEqual([])
  })

  it("kills channels on credit seq gaps", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-credit-gap")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit-gap", seq: 4, bytes: 64 } // expected 1
    })
    expect(closes).toEqual(["protocol-error"])
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "protocol-error" })
  })

  it("tears down a peer's channels on peer-gone, leaving others untouched", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    openEcho(socket, "peer-2", "ch-1")
    const gone: string[] = []
    h.channels[0]!.onClosed = (reason) => gone.push(`peer-1:${reason}`)
    h.channels[1]!.onClosed = (reason) => gone.push(`peer-2:${reason}`)
    socket.receive({ t: "peer-gone", peerId: "peer-1" })
    expect(gone).toEqual(["peer-1:peer-gone"])
    // Survivor still works.
    h.channels[1]!.send({ still: "alive" })
    expect(socket.sentRelay).toHaveLength(1)
  })

  it("drops all channels when the socket drops", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.onclose?.(1006)
    expect(closes).toEqual(["peer-gone"])
  })
})

describe("relay coalescing", () => {
  it("buffers outgoing envelopes and flushes them as one message", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!

    channel.send({ output: "a" })
    channel.send({ output: "b" })
    channel.send({ output: "c" })
    expect(socket.relayMessages).toHaveLength(0)

    activeTimeout(h, 5).run()
    expect(socket.relayMessages).toHaveLength(1)
    const envelopes = socket.relayMessages[0]!
    expect(envelopes.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1, 2])
    expect(
      openJson(opened.cipher, "ch-1", "responder-to-opener", 2, envelopes[2]!.payload)
    ).toEqual({ output: "c" })
  })

  it("drops buffered envelopes when the socket dies before the flush", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    h.channels[0]!.send({ output: "never" })
    const flushTimer = activeTimeout(h, 5)
    socket.onclose?.(1006)
    // Even a queued flush callback firing late must not resurrect the frames.
    flushTimer.invoke()
    expect(socket.relayMessages).toHaveLength(0)
  })
})

describe("negotiated compression", () => {
  const framed = (prefix: number, body: Uint8Array): Uint8Array => {
    const plaintext = new Uint8Array(body.byteLength + 1)
    plaintext[0] = prefix
    plaintext.set(body, 1)
    return plaintext
  }
  const compressingHarness = () =>
    harness({
      compressPayload: (bytes) =>
        bytes.byteLength > 64 ? new Uint8Array(deflateRawSync(bytes)) : undefined,
      decompressPayload: (bytes) => new Uint8Array(inflateRawSync(bytes))
    })

  it("frames payloads in both directions and deflates large bodies", () => {
    const h = compressingHarness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-z", { hello: true }, { compress: true })
    const channel = h.channels[0]!
    const received: unknown[] = []
    channel.onData = (value) => received.push(value)

    // Inbound RAW-framed and DEFLATE-framed payloads both decode.
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 1 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        1,
        framed(0, new TextEncoder().encode(JSON.stringify({ input: "raw" })))
      )
    )
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 2 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        2,
        framed(1, new Uint8Array(deflateRawSync(JSON.stringify({ input: "deflated" }))))
      )
    )
    expect(received).toEqual([{ input: "raw" }, { input: "deflated" }])

    // Outbound: a large repetitive body goes out DEFLATE-framed and smaller;
    // a small one stays RAW.
    channel.send({ output: "x".repeat(4096) })
    channel.send({ output: "tiny" })
    const [big, small] = socket.sentRelay
    const bigPlain = opened.cipher.open("ch-z", "responder-to-opener", 0, big!.payload)
    expect(bigPlain[0]).toBe(1)
    expect(big!.payload.byteLength).toBeLessThan(1024)
    expect(JSON.parse(inflateRawSync(bigPlain.subarray(1)).toString())).toEqual({
      output: "x".repeat(4096)
    })
    const smallPlain = opened.cipher.open("ch-z", "responder-to-opener", 1, small!.payload)
    expect(smallPlain[0]).toBe(0)
    expect(JSON.parse(new TextDecoder().decode(smallPlain.subarray(1)))).toEqual({
      output: "tiny"
    })
  })

  it("honours the framing without a compressor and kills bad framing", () => {
    // No compressor wired: outbound stays RAW-framed; inbound DEFLATE frames
    // cannot be inflated and abort the channel like any undecodable payload.
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-z", { hello: true }, { compress: true })
    const channel = h.channels[0]!
    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)
    channel.send({ output: "plain" })
    const sent = opened.cipher.open("ch-z", "responder-to-opener", 0, socket.sentRelay[0]!.payload)
    expect(sent[0]).toBe(0)

    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 1 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        1,
        framed(1, new Uint8Array(deflateRawSync("{}")))
      )
    )
    expect(closes).toEqual(["crypto-error"])

    // Unknown framing byte and empty plaintexts are refused the same way.
    const again = compressingHarness()
    const socket2 = connect(again)
    const second = openEcho(socket2, "peer-1", "ch-y", { hello: true }, { compress: true })
    const closes2: string[] = []
    again.channels[0]!.onClosed = (reason) => closes2.push(reason)
    socket2.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-y", seq: 1 } },
      second.opened.cipher.seal("ch-y", "opener-to-responder", 1, framed(7, new Uint8Array(0)))
    )
    expect(closes2).toEqual(["crypto-error"])

    const third = compressingHarness()
    const socket3 = connect(third)
    const gone = openEcho(socket3, "peer-1", "ch-x", { hello: true }, { compress: true })
    const closes3: string[] = []
    third.channels[0]!.onClosed = (reason) => closes3.push(reason)
    socket3.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-x", seq: 1 } },
      gone.opened.cipher.seal("ch-x", "opener-to-responder", 1, new Uint8Array(0))
    )
    expect(closes3).toEqual(["crypto-error"])
  })
})
