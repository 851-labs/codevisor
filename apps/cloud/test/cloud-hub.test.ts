import {
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachine,
  type HubToAppRelayHeader,
  type HubToMachineRelayHeader
} from "@codevisor/api"
import {
  acceptChannel,
  fromBase64Url,
  openChannel,
  openJson,
  sealJson,
  toBase64Url
} from "@codevisor/cloud-crypto"
import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import {
  BASE,
  devLogin,
  authed,
  expireResumeGrace,
  disconnect,
  sendRelay,
  connectSocket,
  connectMachine,
  connectApp
} from "./cloud-test-support.js"

describe("hub presence", () => {
  it("registers machines and reflects live presence to apps", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-1")

    const app = await connectApp(token)
    const listed = app.welcome.machines.find((m) => m.deviceId === machine.deviceId)
    expect(listed).toMatchObject({ name: "vps-1", online: true, publicKey: machine.keys.publicKey })

    await disconnect(token, machine.socket, "bye")
    await expireResumeGrace(token)
    const presence = (await app.reader.next()) as Extract<HubToApp, { t: "presence" }>
    expect(presence.t).toBe("presence")
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: false })
  })

  it("lists, renames, and removes machines over REST", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-rest")

    const list = async (): Promise<CloudMachinePresence[]> => {
      const response = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
      expect(response.status).toBe(200)
      return ((await response.json()) as { machines: CloudMachinePresence[] }).machines
    }
    expect((await list()).some((m) => m.deviceId === machine.deviceId && m.online)).toBe(true)

    const renamed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}/rename`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ name: "office-vps" })
    })
    expect(renamed.status).toBe(200)
    expect((await list()).find((m) => m.deviceId === machine.deviceId)?.name).toBe("office-vps")

    const removed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}`, {
      method: "DELETE",
      headers: authed(token)
    })
    expect(removed.status).toBe(200)
    expect((await list()).some((m) => m.deviceId === machine.deviceId)).toBe(false)
    expect(
      (
        await SELF.fetch(`${BASE}/connect`, {
          headers: { Upgrade: "websocket", "x-api-key": machine.apiKey }
        })
      ).status
    ).toBe(401)

    const missing = await SELF.fetch(`${BASE}/api/machines/nope/rename`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ name: "x" })
    })
    expect(missing.status).toBe(404)
  })

  it("closes connections that speak an unsupported protocol", async () => {
    const token = await devLogin()
    const socket = await connectSocket(authed(token))
    const closed = new Promise<number>((resolve) =>
      socket.addEventListener("close", (event) => resolve(event.code))
    )
    socket.send(
      encodeCloudFrame({
        t: "hello",
        protocol: 999,
        device: { deviceId: "d", kind: "app", name: "old app", publicKey: "pk" }
      })
    )
    expect(await closed).toBe(4200)
  })
})

describe("hub relay", () => {
  it("relays sealed channel traffic app↔machine without reading it", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "relay-vps")
    const app = await connectApp(token)

    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const openPayload = {
      channelType: "terminal",
      params: { terminalId: "term-1", sinceSeq: 7 }
    }
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, "ch-1", "opener-to-responder", 0, openPayload)
    )

    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    expect(openHeader.peerPublicKey).toBe(app.keys.publicKey)
    expect(openHeader.peerDeviceId).toBe(app.deviceId)
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )
    expect(openJson(responder, "ch-1", "opener-to-responder", 0, opened.payload)).toEqual(
      openPayload
    )

    sendRelay(
      machine.socket,
      { peerId: openHeader.peerId, frame: { t: "data", channelId: "ch-1", seq: 0 } },
      sealJson(responder, "ch-1", "responder-to-opener", 0, {
        type: "output",
        seq: 8,
        data: "hello from the machine"
      })
    )
    const answered = await app.reader.nextEnvelope()
    const answeredHeader = answered.header as HubToAppRelayHeader
    expect(answeredHeader.machineId).toBe(machine.deviceId)
    expect(openJson(channel.cipher, "ch-1", "responder-to-opener", 0, answered.payload)).toEqual({
      type: "output",
      seq: 8,
      data: "hello from the machine"
    })

    sendRelay(app.socket, {
      machineId: machine.deviceId,
      frame: { t: "credit", channelId: "ch-1", seq: 1, bytes: 65536 }
    })
    const credit = await machine.reader.nextEnvelope()
    expect((credit.header as HubToMachineRelayHeader).frame).toMatchObject({
      t: "credit",
      bytes: 65536
    })
    sendRelay(app.socket, {
      machineId: machine.deviceId,
      frame: { t: "close", channelId: "ch-1", seq: 2, reason: "done" }
    })
    const closeRelay = await machine.reader.nextEnvelope()
    expect((closeRelay.header as HubToMachineRelayHeader).frame.t).toBe("close")
  })

  it("keeps a coalesced envelope batch one message through the hop", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "batch-vps")
    const app = await connectApp(token)
    const before = machine.reader.binaryMessages

    app.socket.send(
      encodeRelayEnvelopes([
        {
          header: { machineId: machine.deviceId, frame: { t: "data", channelId: "b", seq: 0 } },
          payload: new Uint8Array([1])
        },
        {
          header: { machineId: machine.deviceId, frame: { t: "data", channelId: "b", seq: 1 } },
          payload: new Uint8Array([2, 2])
        },
        {
          header: {
            machineId: machine.deviceId,
            frame: { t: "credit", channelId: "b", seq: 2, bytes: 64 }
          },
          payload: new Uint8Array(0)
        }
      ])
    )
    const first = await machine.reader.nextEnvelope()
    const second = await machine.reader.nextEnvelope()
    const third = await machine.reader.nextEnvelope()
    expect([...first.payload]).toEqual([1])
    expect([...second.payload]).toEqual([2, 2])
    expect((third.header as HubToMachineRelayHeader).frame).toMatchObject({ t: "credit" })
    expect(machine.reader.binaryMessages - before).toBe(1)
  })

  it("routes opaque byte-stream data and credit through hibernatable sockets", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "byte-stream-vps")
    const app = await connectApp(token)
    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const channelId = "bytes-1"
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId, seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, channelId, "opener-to-responder", 0, {
        channelType: "byte-stream",
        params: { service: "codevisor-loopback", version: 1 }
      })
    )
    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )

    const requestBytes = new Uint8Array([0, 255, 13, 10, 128, 1])
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId, seq: 1 } },
      channel.cipher.seal(channelId, "opener-to-responder", 1, requestBytes)
    )
    const request = await machine.reader.nextEnvelope()
    expect([...responder.open(channelId, "opener-to-responder", 1, request.payload)]).toEqual([
      ...requestBytes
    ])

    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "credit", channelId, seq: 0, bytes: request.payload.byteLength }
    })
    const credit = await app.reader.nextEnvelope()
    expect((credit.header as HubToAppRelayHeader).frame).toEqual({
      t: "credit",
      channelId,
      seq: 0,
      bytes: request.payload.byteLength
    })

    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")
    const responseBytes = new Uint8Array([9, 8, 7, 0, 255])
    sendRelay(
      machine.socket,
      { peerId: openHeader.peerId, frame: { t: "data", channelId, seq: 1 } },
      responder.seal(channelId, "responder-to-opener", 1, responseBytes)
    )
    const response = await app.reader.nextEnvelope()
    expect([...channel.cipher.open(channelId, "responder-to-opener", 1, response.payload)]).toEqual(
      [...responseBytes]
    )
  })

  it("carries an http channel round-trip through sealed frames", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "http-vps")
    const app = await connectApp(token)

    const localServer = (method: string, path: string) => {
      expect(method).toBe("GET")
      expect(path).toBe("/v1/info")
      return {
        status: 200,
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "http-vps" })
      }
    }

    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const openPayload = {
      channelType: "http",
      params: { method: "GET", path: "/v1/info", headers: { accept: "application/json" } }
    }
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId: "http-1", seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, "http-1", "opener-to-responder", 0, openPayload)
    )
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "http-1", seq: 1 } },
      sealJson(channel.cipher, "http-1", "opener-to-responder", 1, { kind: "end" })
    )

    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )
    const request = openJson(responder, "http-1", "opener-to-responder", 0, opened.payload) as {
      params: { method: string; path: string }
    }
    expect(request).toEqual(openPayload)
    const ended = await machine.reader.nextEnvelope()
    expect(openJson(responder, "http-1", "opener-to-responder", 1, ended.payload)).toEqual({
      kind: "end"
    })

    const response = localServer(request.params.method, request.params.path)
    const answer = (seq: number, value: unknown): void =>
      sendRelay(
        machine.socket,
        { peerId: openHeader.peerId, frame: { t: "data", channelId: "http-1", seq } },
        sealJson(responder, "http-1", "responder-to-opener", seq, value)
      )
    answer(0, { kind: "head", status: response.status, headers: response.headers })
    answer(1, { kind: "chunk", data: toBase64Url(new TextEncoder().encode(response.body)) })
    answer(2, { kind: "end" })
    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "close", channelId: "http-1", seq: 3, reason: "done" }
    })

    const read = async (seq: number): Promise<unknown> => {
      const relayed = await app.reader.nextEnvelope()
      return openJson(channel.cipher, "http-1", "responder-to-opener", seq, relayed.payload)
    }
    expect(await read(0)).toEqual({
      kind: "head",
      status: 200,
      headers: { "content-type": "application/json" }
    })
    const chunk = (await read(1)) as { kind: string; data: string }
    expect(chunk.kind).toBe("chunk")
    expect(new TextDecoder().decode(fromBase64Url(chunk.data))).toBe(response.body)
    expect(await read(2)).toEqual({ kind: "end" })
    const closed = await app.reader.nextEnvelope()
    expect((closed.header as HubToAppRelayHeader).frame).toMatchObject({
      t: "close",
      channelId: "http-1",
      reason: "done"
    })
  })

  it("reports offline and unknown machines to the app", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "flaky-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "gone")
    await expireResumeGrace(token)
    expect((await app.reader.next()).t).toBe("presence")
    const broadcast = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(broadcast).toMatchObject({
      t: "error",
      code: "machine-offline",
      machineId: machine.deviceId
    })

    const frame = { t: "data", channelId: "ch-x", seq: 0 } as const
    sendRelay(app.socket, { machineId: machine.deviceId, frame }, new Uint8Array([1]))
    const offline = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(offline).toMatchObject({ t: "error", code: "machine-offline", channelId: "ch-x" })

    sendRelay(app.socket, { machineId: "never-existed", frame }, new Uint8Array([1]))
    const unknown = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(unknown.code).toBe("unknown-machine")
  })

  it("resets app channels and supersedes zombie sockets when a machine re-hellos", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "reconnect-vps")
    const app = await connectApp(token)

    const superseded = new Promise<number>((resolve) =>
      machine.socket.addEventListener("close", (event) => resolve(event.code))
    )
    const reborn = await connectMachine(token, "reconnect-vps", machine.deviceId)

    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "ch-fresh", seq: 0 } },
      new Uint8Array([1])
    )
    const relayed = await reborn.reader.nextEnvelope()
    expect((relayed.header as HubToMachineRelayHeader).frame).toMatchObject({
      channelId: "ch-fresh"
    })

    expect(await superseded).toBe(4003)
    const reset = (await app.reader.next()) as Extract<HubToApp, { t: "machine-reset" }>
    expect(reset).toMatchObject({ t: "machine-reset", machineId: machine.deviceId })
    const presence = (await app.reader.next()) as Extract<HubToApp, { t: "presence" }>
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: true })
  })

  it("notifies machines when an app peer disconnects for good", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "peer-vps")
    const app = await connectApp(token)
    await disconnect(token, app.socket, "app quit")
    await expireResumeGrace(token)
    const gone = (await machine.reader.next()) as Extract<HubToMachine, { t: "peer-gone" }>
    expect(gone).toMatchObject({ t: "peer-gone", peerId: app.welcome.connectionId })
  })

  it("answers protocol pings and rejects garbage frames", async () => {
    const token = await devLogin()
    const app = await connectApp(token)
    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")

    const machine = await connectMachine(token, "heartbeat-vps")
    expect((await app.reader.next()).t).toBe("machine-reset")
    expect((await app.reader.next()).t).toBe("presence")
    machine.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await machine.reader.next()).t).toBe("pong")

    app.socket.send("this is not json")
    const notJson = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(notJson.code).toBe("invalid-frame")

    app.socket.send(new Uint8Array([0, 0, 0, 99]).buffer)
    const truncated = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(truncated.code).toBe("invalid-frame")

    app.socket.send(encodeRelayEnvelopes([{ header: { nope: true }, payload: new Uint8Array(0) }]))
    const badHeader = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(badHeader.code).toBe("invalid-frame")
  })
})
