// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  encodeCloudFrame,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachineRelayHeader
} from "@codevisor/api"
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
  connectApp
} from "./cloud-test-support.js"

describe("session resume", () => {
  it("an app resume keeps its peer identity and replays buffered frames", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "resume-vps")
    const app = await connectApp(token)
    expect(typeof app.welcome.resume).toBe("string")

    await disconnect(token, app.socket, "subway tunnel")
    // Machines are never told; frames they send meanwhile are buffered.
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
    // Tokens rotate: the new welcome carries a fresh one.
    expect(revived.welcome.resume).not.toBe(app.welcome.resume)

    const first = await revived.reader.nextEnvelope()
    const second = await revived.reader.nextEnvelope()
    expect([...first.payload]).toEqual([1, 2])
    expect([...second.payload]).toEqual([3])
    // The machine never saw a peer-gone; it can keep relaying to the same id.
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
    // The machine still lists as online, and app frames buffer silently.
    const listed = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
    const machines = ((await listed.json()) as { machines: CloudMachinePresence[] }).machines
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
    expect((replayed.header as HubToMachineRelayHeader).peerId).toBe(app.welcome.connectionId)

    // Apps saw neither machine-reset nor presence churn: the next control
    // frame the app receives is its own pong.
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
    // Fresh hello → apps must drop their channels toward the machine.
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
    // The expired token can no longer resume.
    const reborn = await connectMachine(token, "expiry-vps", machine.deviceId, {
      apiKey: machine.apiKey,
      keys: machine.keys,
      resume: machine.welcome.resume!
    })
    expect(reborn.welcome.resumed).toBeUndefined()
  })

  it("buffer overflow abandons the session and reports the machine offline", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "overflow-vps")
    const app = await connectApp(token)
    await disconnect(token, machine.socket, "away")

    // Fill past the 256 KiB cap: five 64 KiB payloads.
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
    // Abandoning the session fires the deferred death notices immediately
    // (offline presence + broadcast error), then the sender's own error.
    expect((await app.reader.next()).t).toBe("presence")
    const overflow = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(overflow).toMatchObject({ t: "error", machineId: machine.deviceId })
    // The abandoned session cannot resume any more.
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

    // A stream in flight, machine → app.
    sendRelay(
      machine.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "st", seq: 0 } },
      new Uint8Array([0])
    )
    expect([...(await app.reader.nextEnvelope()).payload]).toEqual([0])

    // The deploy: every edge socket closes at once.
    await disconnect(token, machine.socket, "deploy")
    await disconnect(token, app.socket, "deploy")

    // The machine reconnects first and keeps streaming; the app is still
    // away, so the frame lands in its resume buffer.
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
    // Presence never flapped: the machine shows online in the new welcome.
    expect(app2.welcome.machines.find((m) => m.deviceId === machine.deviceId)?.online).toBe(true)
    // The mid-deploy frame replays, then the live stream just continues.
    expect([...(await app2.reader.nextEnvelope()).payload]).toEqual([1])
    sendRelay(
      machine2.socket,
      { peerId: app.welcome.connectionId, frame: { t: "data", channelId: "st", seq: 2 } },
      new Uint8Array([2])
    )
    expect([...(await app2.reader.nextEnvelope()).payload]).toEqual([2])
    // Upstream still routes with the original addressing.
    sendRelay(app2.socket, {
      machineId: machine.deviceId,
      frame: { t: "credit", channelId: "st", seq: 0, bytes: 3 }
    })
    expect((await machine2.reader.nextEnvelope()).header).toMatchObject({
      peerId: app.welcome.connectionId,
      frame: { t: "credit", bytes: 3 }
    })

    // Neither side ever heard a death notice: a ping round-trips with
    // nothing queued ahead of the pong.
    app2.socket.send(encodeCloudFrame({ t: "ping" }))
    expect(((await app2.reader.next()) as { t: string }).t).toBe("pong")
    machine2.socket.send(encodeCloudFrame({ t: "ping" }))
    expect(((await machine2.reader.next()) as { t: string }).t).toBe("pong")
  })
})
