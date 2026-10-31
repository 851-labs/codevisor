import { encodeCloudFrame } from "@codevisor/api"
import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import {
  BASE,
  devLogin,
  authed,
  expireResumeGrace,
  disconnect,
  sendRelay,
  connectMachine,
  connectApp,
  machineRelayHeader
} from "./cloud-test-support.js"
import { MachinesBody, readJson } from "./json-test-support.js"

describe("session resume", () => {
  it("an app resume keeps its peer identity and replays buffered frames", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "resume-vps")
    const app = await connectApp(token)
    expect(typeof app.welcome.resume).toBe("string")

    await disconnect(token, app.socket, "subway tunnel")
    sendRelay(
      machine.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "ch-r", seq: 0 } },
      new Uint8Array([1, 2])
    )
    sendRelay(
      machine.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "ch-r", seq: 1 } },
      new Uint8Array([3])
    )

    const revived = await connectApp(token, {
      keys: app.keys,
      deviceId: app.deviceId,
      resume: app.welcome.resume!
    })
    expect(revived.welcome.resumed).toBe(true)
    expect(revived.welcome.connectionId).toBe(app.welcome.connectionId)
    expect(revived.welcome.resume).not.toBe(app.welcome.resume)

    const first = await revived.reader.nextEnvelope()
    const second = await revived.reader.nextEnvelope()
    expect([...first.payload]).toEqual([1, 2])
    expect([...second.payload]).toEqual([3])
    sendRelay(
      machine.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "ch-r", seq: 2 } },
      new Uint8Array([4])
    )
    expect([...(await revived.reader.nextEnvelope()).payload]).toEqual([4])
  })

  it("a machine resume is invisible to apps and replays buffered frames", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "resume-machine")
    const app = await connectApp(token)

    await disconnect(token, machine.socket, "worker deploy")
    const listed = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
    const machines = (await readJson(listed, MachinesBody)).machines
    expect(machines.find((m) => m.deviceId === machine.deviceId)?.online).toBe(true)
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "ch-m", seq: 5 } },
      new Uint8Array([9, 9])
    )

    const revived = await connectMachine(token, "resume-machine", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: machine.welcome.resume!
    })
    expect(revived.welcome.resumed).toBe(true)
    expect(revived.welcome.connectionId).toBe(machine.welcome.connectionId)
    const replayed = await revived.reader.nextEnvelope()
    expect([...replayed.payload]).toEqual([9, 9])
    expect(machineRelayHeader(replayed).peerId).toBe(app.welcome.connectionId)

    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")
  })

  it("a wrong token falls back to a fresh identity (machine-reset fires)", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "fresh-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "restart")

    const reborn = await connectMachine(token, "fresh-vps", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: "not-a-valid-token"
    })
    expect(reborn.welcome.resumed).toBeUndefined()
    expect(reborn.welcome.connectionId).not.toBe(machine.welcome.connectionId)
    expect((await app.reader.next()).t).toBe("machine-reset")
    expect((await app.reader.next()).t).toBe("presence")
  })

  it("expired sessions deliver the deferred death notices exactly once", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "expiry-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "gone for good")
    await expireResumeGrace(token)
    expect((await app.reader.next()).t).toBe("presence")
    expect((await app.reader.next()).t).toBe("error")
    const reborn = await connectMachine(token, "expiry-vps", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: machine.welcome.resume!
    })
    expect(reborn.welcome.resumed).toBeUndefined()
    expect(await app.reader.next()).toMatchObject({
      t: "machine-reset",
      machineId: machine.deviceId
    })
    expect(await app.reader.next()).toMatchObject({
      t: "presence",
      machine: { deviceId: machine.deviceId, online: true }
    })
  })

  it("an expired session tells openers their buffered channels are lost", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "expiry-buffer-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "deploy")
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "ch-lost", seq: 1 } },
      new Uint8Array([5])
    )
    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")
    await expireResumeGrace(token)
    expect((await app.reader.next()).t).toBe("presence")
    expect(await app.reader.next()).toMatchObject({ t: "error", machineId: machine.deviceId })
    expect(await app.reader.next()).toMatchObject({
      t: "error",
      code: "machine-offline",
      machineId: machine.deviceId,
      channelId: "ch-lost"
    })
  })

  it("buffer overflow abandons the session and reports the machine offline", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "overflow-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "away")

    const chunk = new Uint8Array(64 * 1024).fill(7)
    for (let index = 0; index < 4; index += 1) {
      sendRelay(
        app.socket,
        { machineId: machine.deviceId, frame: { t: "data", channelId: "big", seq: index } },
        chunk
      )
    }
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "big", seq: 4 } },
      chunk
    )
    expect((await app.reader.next()).t).toBe("presence")
    const overflow = await app.reader.nextFrame("error")
    expect(overflow).toMatchObject({ t: "error", machineId: machine.deviceId })
    const reborn = await connectMachine(token, "overflow-vps", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: machine.welcome.resume!
    })
    expect(reborn.welcome.resumed).toBeUndefined()
  })
})

describe("resilience matrix", () => {
  it("rolling deploy: both sockets drop mid-stream and the stream resumes seamlessly", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "deploy-stream-vps")
    const app = await connectApp(token)

    sendRelay(
      machine.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "st", seq: 0 } },
      new Uint8Array([0])
    )
    expect([...(await app.reader.nextEnvelope()).payload]).toEqual([0])

    await disconnect(token, machine.socket, "deploy")
    await disconnect(token, app.socket, "deploy")

    const machine2 = await connectMachine(token, "deploy-stream-vps", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: machine.welcome.resume!
    })
    expect(machine2.welcome.resumed).toBe(true)
    sendRelay(
      machine2.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "st", seq: 1 } },
      new Uint8Array([1])
    )

    const app2 = await connectApp(token, {
      keys: app.keys,
      deviceId: app.deviceId,
      resume: app.welcome.resume!
    })
    expect(app2.welcome.resumed).toBe(true)
    expect(app2.welcome.machines.find((m) => m.deviceId === machine.deviceId)?.online).toBe(true)
    expect([...(await app2.reader.nextEnvelope()).payload]).toEqual([1])
    sendRelay(
      machine2.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "st", seq: 2 } },
      new Uint8Array([2])
    )
    expect([...(await app2.reader.nextEnvelope()).payload]).toEqual([2])
    sendRelay(app2.socket, {
      machineId: machine.deviceId,
      frame: { t: "credit", channelId: "st", seq: 0, bytes: 3 }
    })
    expect((await machine2.reader.nextEnvelope()).header).toMatchObject({
      peerId: app.welcome.connectionId,
      frame: { t: "credit", bytes: 3 }
    })

    app2.socket.send(encodeCloudFrame({ t: "ping" }))
    expect(((await app2.reader.next()) as { t: string }).t).toBe("pong")
    machine2.socket.send(encodeCloudFrame({ t: "ping" }))
    expect(((await machine2.reader.next()) as { t: string }).t).toBe("pong")
  })
})
