import { encodeCloudFrame, encodeRelayEnvelopes, type CloudMachinePresence } from "@codevisor/api"
import { acceptChannel, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
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
  connectApp,
  appRelayHeader,
  expectDefined,
  expectTag,
  machineRelayHeader
} from "./cloud-test-support.js"
import { MachinesBody, readJson } from "./json-test-support.js"

describe("hub presence", () => {
  it("registers machines and reflects live presence to apps", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-1")

    const app = await connectApp(token)
    const listed = app.welcome.machines.find((m) => m.deviceId === machine.deviceId)
    expect(listed).toMatchObject({ name: "vps-1", online: true, publicKey: machine.keys.publicKey })

    await disconnect(token, machine.socket, "bye")
    await expireResumeGrace(token)
    const presence = await app.reader.nextFrame("presence")
    expect(presence.t).toBe("presence")
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: false })
  })

  it("lists, renames, and removes machines over REST", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-rest")

    const list = async (): Promise<CloudMachinePresence[]> => {
      const response = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
      expect(response.status).toBe(200)
      return (await readJson(response, MachinesBody)).machines
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

  it("keeps a machine's edited name and icon over the one it reports when it reconnects", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-edit", undefined, { icon: "laptopcomputer" })
    const update = (body: unknown) =>
      SELF.fetch(`${BASE}/api/machines/${machine.deviceId}`, {
        method: "PATCH",
        headers: { "content-type": "application/json", ...authed(token) },
        body: JSON.stringify(body)
      })
    const listed = async (): Promise<CloudMachinePresence | undefined> => {
      const response = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
      const { machines } = await readJson(response, MachinesBody)
      return machines.find((m) => m.deviceId === machine.deviceId)
    }
    expect(await listed()).toMatchObject({ name: "vps-edit", icon: "laptopcomputer" })

    expect((await update({ name: " Build box ", icon: "server.rack" })).status).toBe(200)
    expect(await listed()).toMatchObject({ name: "Build box", icon: "server.rack" })

    await disconnect(token, machine.socket, "restart")
    await connectMachine(token, "vps-edit", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      icon: "laptopcomputer"
    })
    expect(await listed()).toMatchObject({ name: "Build box", icon: "server.rack" })

    expect((await update({ icon: "../etc" })).status).toBe(400)
    expect((await update({ icon: null })).status).toBe(400)
    expect((await update({ name: "" })).status).toBe(400)
    expect((await update({})).status).toBe(400)
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
    const openHeader = machineRelayHeader(opened)
    expect(openHeader.peerPublicKey).toBe(app.keys.publicKey)
    expect(openHeader.peerDeviceId).toBe(app.deviceId)
    const openFrame = expectTag(openHeader.frame, "open")
    const responder = acceptChannel(
      machine.keys.secretKey,
      expectDefined(openHeader.peerPublicKey),
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
    const answeredHeader = appRelayHeader(answered)
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
    expect(machineRelayHeader(credit).frame).toMatchObject({
      t: "credit",
      bytes: 65536
    })
    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "credit", channelId: "ch-1", seq: 1, bytes: 4096 }
    })
    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "close", channelId: "ch-1", seq: 2, reason: "done" }
    })
    expect(appRelayHeader(await app.reader.nextEnvelope()).frame).toEqual({
      t: "credit",
      channelId: "ch-1",
      seq: 1,
      bytes: 4096
    })
    expect(appRelayHeader(await app.reader.nextEnvelope()).frame).toEqual({
      t: "close",
      channelId: "ch-1",
      seq: 2,
      reason: "done"
    })

    sendRelay(app.socket, {
      machineId: machine.deviceId,
      frame: { t: "close", channelId: "ch-1", seq: 2, reason: "done" }
    })
    const closeRelay = await machine.reader.nextEnvelope()
    expect(machineRelayHeader(closeRelay).frame).toEqual({
      t: "close",
      channelId: "ch-1",
      seq: 2,
      reason: "done"
    })
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
    expect(machineRelayHeader(third).frame).toMatchObject({ t: "credit" })
    expect(machine.reader.binaryMessages - before).toBe(1)
  })

  it("reports offline and unknown machines to the app", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "flaky-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "gone")
    await expireResumeGrace(token)
    expect((await app.reader.next()).t).toBe("presence")
    const broadcast = await app.reader.nextFrame("error")
    expect(broadcast).toMatchObject({
      t: "error",
      code: "machine-offline",
      machineId: machine.deviceId
    })

    const frame = { t: "data", channelId: "ch-x", seq: 0 } as const
    sendRelay(app.socket, { machineId: machine.deviceId, frame }, new Uint8Array([1]))
    const offline = await app.reader.nextFrame("error")
    expect(offline).toMatchObject({ t: "error", code: "machine-offline", channelId: "ch-x" })

    sendRelay(app.socket, { machineId: "never-existed", frame }, new Uint8Array([1]))
    const unknown = await app.reader.nextFrame("error")
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
    expect(machineRelayHeader(relayed).frame).toMatchObject({
      channelId: "ch-fresh"
    })

    expect(await superseded).toBe(4003)
    const reset = await app.reader.nextFrame("machine-reset")
    expect(reset).toMatchObject({ t: "machine-reset", machineId: machine.deviceId })
    const presence = await app.reader.nextFrame("presence")
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: true })
  })

  it("notifies machines when an app peer disconnects for good", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "peer-vps")
    const app = await connectApp(token)
    await disconnect(token, app.socket, "app quit")
    await expireResumeGrace(token)
    const gone = await machine.reader.nextFrame("peer-gone")
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
    const notJson = await app.reader.nextFrame("error")
    expect(notJson.code).toBe("invalid-frame")
  })
})
