import { type CloudDeviceInfo, encodeCloudFrame } from "@codevisor/api"
import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import type { CloudEnv } from "../src/env.js"
import { machineTunnelScope } from "../src/hub-tunnel-events.js"
import { relayMap, tunnelRollout, tunnelScopedDevice } from "../src/hub-tunnel.js"
import { registerTunnelEndpoint } from "../src/relay-routes.js"
import { authed, BASE, connectApp, connectMachine, devLogin } from "./cloud-test-support.js"

// The hub's tunnel control plane (docs/plans/codevisor-tunnel.md): it
// introduces devices (endpoint ids, addresses, vouched app keys) and gates
// our relays; it never carries tunnel traffic.

const endpointId = (fill: string): string => fill.repeat(64)

/// Exactly what the pinned iroh-relay sends (captured from v1.2.0).
const authorize = (endpoint: string, token = "relay-secret"): Promise<Response> =>
  SELF.fetch(`${BASE}/api/relay/authorize`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "x-iroh-nodeid": endpoint, accept: "*/*" }
  })

describe("tunnel control plane", () => {
  it("advertises the relay map and rollout in discovery and both welcomes", async () => {
    const relays = [{ url: "https://relay-test.codevisor.dev", quicPort: 7842 }]
    const discovery = (await (await SELF.fetch(`${BASE}/.well-known/codevisor`)).json()) as {
      relays: unknown
    }
    expect(discovery.relays).toEqual(relays)

    const token = await devLogin()
    const machine = await connectMachine(token, "Relay Map Machine")
    expect(machine.welcome).toMatchObject({ relays, tunnel: "on" })
    const app = await connectApp(token)
    expect(app.welcome).toMatchObject({ relays, tunnel: "on" })
  })

  it("publishes a machine's endpoint and reported address to apps", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "Tunnel Machine", undefined, {
      tunnelEndpointId: endpointId("a")
    })
    const app = await connectApp(token)
    const listed = app.welcome.machines.find((entry) => entry.deviceId === machine.deviceId)
    expect(listed?.tunnel).toEqual({ endpointId: endpointId("a"), directAddrs: [] })

    const reported = {
      endpointId: endpointId("a"),
      relayUrl: "https://relay-test.codevisor.dev/",
      directAddrs: ["192.168.1.20:41641", "203.0.113.9:41641"]
    }
    machine.socket.send(encodeCloudFrame({ t: "tunnel-addr", tunnel: reported }))
    const presence = await app.reader.next()
    expect(presence).toMatchObject({ t: "presence", machine: { deviceId: machine.deviceId } })
    expect(presence.t === "presence" ? presence.machine.tunnel : undefined).toEqual(reported)

    // A report for some other endpoint is ignored; the stored address stays.
    machine.socket.send(
      encodeCloudFrame({
        t: "tunnel-addr",
        tunnel: { endpointId: endpointId("b"), directAddrs: ["10.0.0.1:1"] }
      })
    )
    const rejoined = await connectApp(token)
    expect(
      rejoined.welcome.machines.find((entry) => entry.deviceId === machine.deviceId)?.tunnel
    ).toEqual(reported)
  })

  it("vouches for the account's app devices to tunnel machines only", async () => {
    const token = await devLogin()
    const tunnelMachine = await connectMachine(token, "Vouching Machine", undefined, {
      tunnelEndpointId: endpointId("c")
    })
    expect(await tunnelMachine.reader.next()).toMatchObject({ t: "peer-devices" })
    const legacyMachine = await connectMachine(token, "Legacy Machine")

    const app = await connectApp(token, { tunnelEndpointId: endpointId("d") })
    const update = await tunnelMachine.reader.next()
    expect(update.t).toBe("peer-devices")
    expect(update.t === "peer-devices" ? update.devices : []).toContainEqual({
      deviceId: app.deviceId,
      publicKey: app.keys.publicKey,
      endpointId: endpointId("d")
    })

    // Legacy machines never receive tunnel frames: their next frame is the
    // answer to this ping.
    legacyMachine.socket.send(encodeCloudFrame({ t: "ping" }))
    expect(await legacyMachine.reader.next()).toEqual({ t: "pong" })
  })

  it("lets relays admit exactly the registered endpoints", async () => {
    const token = await devLogin()
    const unknown = endpointId("e")
    expect(await (await authorize(unknown)).text()).toBe("false")

    const machine = await connectMachine(token, "Relay Machine", undefined, {
      tunnelEndpointId: endpointId("f")
    })
    const admitted = await authorize(endpointId("f"))
    expect(admitted.status).toBe(200)
    expect(await admitted.text()).toBe("true")
    // Either configured token works (rotation), a wrong one never does.
    expect(await (await authorize(endpointId("f"), "relay-next")).text()).toBe("true")
    expect((await authorize(endpointId("f"), "nope")).status).toBe(401)
    expect((await authorize("not-an-endpoint")).status).toBe(403)
    // The header name iroh's docs use is accepted too.
    const documented = await SELF.fetch(`${BASE}/api/relay/authorize`, {
      method: "POST",
      headers: { authorization: "Bearer relay-secret", "x-iroh-endpoint-id": endpointId("f") }
    })
    expect(await documented.text()).toBe("true")

    // Removing the machine revokes its relay access.
    const removed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}`, {
      method: "DELETE",
      headers: authed(token)
    })
    expect(removed.status).toBe(200)
    expect(await (await authorize(endpointId("f"))).text()).toBe("false")
  })

  it("ignores malformed relay map entries", () => {
    expect(relayMap({})).toEqual([])
    expect(relayMap({ RELAY_MAP: "not json" })).toEqual([])
    expect(relayMap({ RELAY_MAP: '{"url":"https://x"}' })).toEqual([])
    expect(
      relayMap({
        RELAY_MAP: JSON.stringify([
          { url: "http://insecure.example" },
          null,
          { url: "https://ok.example" }
        ])
      })
    ).toEqual([{ url: "https://ok.example" }])
  })

  it("turns the tunnel on per connection: for everyone, for Alpha devices only, or never", () => {
    const stable = { releaseChannel: "stable" as const }
    const alpha = { releaseChannel: "alpha" as const }
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "on" }, stable)).toBe("on")
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "alpha" }, alpha)).toBe("on")
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "alpha" }, stable)).toBe("off")
    // Devices that predate the channel field count as stable.
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "alpha" }, {})).toBe("off")
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "off" }, alpha)).toBe("off")
    expect(tunnelRollout({ TUNNEL_ROLLOUT: "bogus" }, alpha)).toBe("off")
    expect(tunnelRollout({}, alpha)).toBe("off")
  })

  it("hides the tunnel identity of devices whose connection doesn't get the tunnel", () => {
    const device: CloudDeviceInfo = {
      deviceId: "m1",
      kind: "machine",
      name: "Stable Mac",
      publicKey: "key",
      tunnelEndpointId: endpointId("a"),
      releaseChannel: "stable"
    }
    const { tunnelEndpointId: _endpoint, ...withoutTunnel } = device
    expect(machineTunnelScope({ TUNNEL_ROLLOUT: "alpha" }, device)).toEqual({
      welcome: { relays: [], tunnel: "off" },
      device: withoutTunnel,
      tunnelMachine: false
    })
    expect(machineTunnelScope({ TUNNEL_ROLLOUT: "on" }, device)).toEqual({
      welcome: { relays: [], tunnel: "on" },
      device,
      tunnelMachine: true
    })
    expect(tunnelScopedDevice(withoutTunnel, "off")).toBe(withoutTunnel)
  })

  it("registers relay access on a best-effort basis, and not at all while the tunnel is off", async () => {
    const registration = {
      endpointId: endpointId("c"),
      userId: "user",
      deviceId: "device",
      kind: "machine"
    }
    const failingDb = {
      prepare: () => {
        throw new Error("D1 unavailable")
      }
    }
    const logged: unknown[] = []
    const env = (TUNNEL_ROLLOUT: string) =>
      ({ DB: failingDb, TUNNEL_ROLLOUT }) as unknown as CloudEnv
    await registerTunnelEndpoint(env("off"), registration, (...entry) => logged.push(entry))
    expect(logged).toEqual([])
    await registerTunnelEndpoint(env("alpha"), registration, (...entry) => logged.push(entry))
    expect(logged).toEqual([["tunnel endpoint registration failed", new Error("D1 unavailable")]])
  })
})
