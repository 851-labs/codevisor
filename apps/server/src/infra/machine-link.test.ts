import type { CloudMachinePresence } from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"
import { GatewayChannelError } from "@codevisor/cloud-client"
import { describe, expect, it } from "vitest"

import {
  DirectPathError,
  type DirectAnswer,
  type DirectProbe,
  type DirectRoute
} from "./machine-direct.js"
import {
  makeMachineLink,
  relativeAge,
  rosterRoutes,
  type MachineLinkCloud,
  type RosterRoute
} from "./machine-link.js"

const NOW = Date.parse("2100-01-01T12:00:00.000Z")
const origin = { machineId: "machine-self", machineName: "Studio", sessionId: "s-1" }

const presence = (overrides: Partial<CloudMachinePresence> = {}): CloudMachinePresence => ({
  deviceId: "device-laptop",
  serverId: "machine-laptop",
  name: "Laptop",
  os: "darwin",
  publicKey: "key",
  online: true,
  lastSeenAt: "2100-01-01T11:57:00.000Z",
  ...overrides
})

const ok = (result: unknown): DirectAnswer => ({ status: 200, body: JSON.stringify({ result }) })

/// A link over scripted paths; each path records the bodies it was asked to
/// deliver so tests can prove what did (and did not) get sent.
const link = (
  options: {
    machines?: CloudMachinePresence[] | undefined
    roster?: RosterRoute[]
    direct?: (route: DirectRoute) => Promise<DirectAnswer>
    cloud?: (deviceId: string) => Promise<DirectAnswer>
    probe?: (route: DirectRoute) => Promise<DirectProbe>
  } = {}
) => {
  const sent = { direct: [] as unknown[], cloud: [] as unknown[], probes: 0 }
  const cloud: MachineLinkCloud = {
    deviceId: () => "device-self",
    machines: () => ("machines" in options ? options.machines : [presence()]),
    request: async (deviceId, body) => {
      sent.cloud.push(JSON.parse(body))
      return (options.cloud ?? (async () => ok("via cloud")))(deviceId)
    }
  }
  const machineLink = makeMachineLink({
    self: { id: "machine-self", name: () => "Studio", os: "darwin" },
    cloud,
    roster: async () => options.roster ?? [],
    direct: async (route, body) => {
      sent.direct.push(JSON.parse(body))
      return (options.direct ?? (async () => ok("via direct")))(route)
    },
    probe: async (route) => {
      sent.probes += 1
      return (options.probe ?? (async () => ({ online: false })))(route)
    },
    now: () => NOW
  })
  return { machineLink, sent }
}

const failure = async (promise: Promise<unknown>): Promise<CodeExecutionToolError> => {
  const error = await promise.then(
    () => undefined,
    (cause: unknown) => cause
  )
  expect(error).toBeInstanceOf(CodeExecutionToolError)
  return error as CodeExecutionToolError
}

const laptopRoute: RosterRoute = {
  id: "machine-laptop",
  name: "my laptop",
  url: "http://laptop:49361",
  token: "t"
}

describe("machine list", () => {
  it("merges this machine, hub presence, and roster routes under stable ids", async () => {
    const { machineLink } = link({
      machines: [
        presence(),
        // This machine's own presence entry is not a second machine.
        presence({ deviceId: "device-self", serverId: "machine-self", name: "Studio" }),
        // Older servers publish no server id.
        presence({
          deviceId: "device-old",
          serverId: undefined,
          name: "Old",
          os: undefined,
          online: false
        })
      ],
      roster: [
        laptopRoute,
        { id: "machine-self", url: "http://self" },
        { id: "machine-linux", url: "http://linux:49361" }
      ],
      // The direct machine's own discovery answer supplies its platform.
      probe: async (route) =>
        route.url === "http://linux:49361" ? { online: true, os: "linux" } : { online: false }
    })
    expect(await machineLink.list()).toEqual([
      { id: "machine-self", name: "Studio", os: "darwin", online: true, isCurrent: true },
      {
        id: "machine-laptop",
        name: "Laptop",
        os: "darwin",
        online: true,
        lastSeen: "2100-01-01T11:57:00.000Z",
        isCurrent: false
      },
      {
        id: "cloud:device-old",
        name: "Old",
        online: false,
        lastSeen: "2100-01-01T11:57:00.000Z",
        isCurrent: false
      },
      {
        id: "machine-linux",
        name: "http://linux:49361",
        os: "linux",
        online: true,
        lastSeen: "2100-01-01T12:00:00.000Z",
        isCurrent: false
      }
    ])
  })

  it("probes direct-only machines at most once per freshness window", async () => {
    const { machineLink, sent } = link({ machines: undefined, roster: [laptopRoute] })
    expect((await machineLink.list())[1]).toEqual({
      id: "machine-laptop",
      name: "my laptop",
      online: false,
      isCurrent: false
    })
    await machineLink.list()
    expect(sent.probes).toBe(1)
  })

  it("reads live FleetRoster routes and skips tombstones and junk", () => {
    const timestamp = { wallTime: 1, logical: 0, origin: "x" }
    expect(
      rosterRoutes([
        { key: "machine-a", value: { name: "A", url: "http://a", token: "t" }, timestamp },
        { key: "machine-b", value: { url: "http://b" }, timestamp },
        { key: "machine-c", value: { url: "http://c" }, deleted: true, timestamp },
        { key: "machine-d", value: "nonsense", timestamp },
        { key: "machine-e", value: { name: "no url" }, timestamp }
      ] as never)
    ).toEqual([
      { id: "machine-a", name: "A", url: "http://a", token: "t" },
      { id: "machine-b", url: "http://b" }
    ])
  })
})

describe("machine calls", () => {
  it("prefers the direct route and sends the call with its origin", async () => {
    const { machineLink, sent } = link({ roster: [laptopRoute] })
    expect(
      await machineLink.invoke("machine-laptop", "xcode.build", { scheme: "App" }, origin)
    ).toBe("via direct")
    expect(sent.direct).toEqual([{ path: "xcode.build", args: { scheme: "App" }, origin }])
    expect(sent.cloud).toEqual([])
  })

  it("resolves machines by case-insensitive name", async () => {
    const { machineLink } = link()
    expect(await machineLink.invoke("LAPTOP", "search", {}, origin)).toBe("via cloud")
  })

  it.each([
    [
      "the connect fails",
      async () => Promise.reject(new DirectPathError("before-send", "refused"))
    ],
    ["the token is rejected", async () => ({ status: 401, body: '{"error":"Unauthorized"}' })]
  ])("falls back to the relay when %s", async (_label, direct) => {
    const { machineLink, sent } = link({ roster: [laptopRoute], direct })
    expect(await machineLink.invoke("machine-laptop", "search", {}, origin)).toBe("via cloud")
    expect(sent.cloud).toHaveLength(1)
  })

  it("never retries once the request may have reached the target", async () => {
    const { machineLink, sent } = link({
      roster: [laptopRoute],
      direct: async () => Promise.reject(new DirectPathError("in-flight", "socket hang up"))
    })
    const error = await failure(machineLink.invoke("machine-laptop", "xcode.build", {}, origin))
    expect(error.message).toBe(
      "Lost connection to Laptop mid-call; the tool may or may not have completed"
    )
    expect(error.code).toBe("machine_unavailable")
    expect(error.details).toEqual({
      machineId: "machine-laptop",
      name: "Laptop",
      lastSeen: "2100-01-01T11:57:00.000Z",
      phase: "in-flight"
    })
    expect(sent.cloud).toEqual([])
  })

  it("reports a relay loss mid-call as in-flight", async () => {
    const { machineLink } = link({
      cloud: async () => Promise.reject(new GatewayChannelError("in-flight", "peer-gone"))
    })
    const error = await failure(machineLink.invoke("machine-laptop", "search", {}, origin))
    expect(error.details).toMatchObject({ phase: "in-flight" })
  })

  it("reports an unreachable machine as offline with its last-seen age", async () => {
    const { machineLink } = link({
      roster: [laptopRoute],
      direct: async () => Promise.reject(new DirectPathError("before-send", "refused")),
      cloud: async () => Promise.reject(new GatewayChannelError("before-send", "undeliverable"))
    })
    const error = await failure(machineLink.invoke("machine-laptop", "search", {}, origin))
    expect(error.message).toBe("Laptop is offline (last seen 3m ago)")
    expect(error.details).toEqual({
      machineId: "machine-laptop",
      name: "Laptop",
      lastSeen: "2100-01-01T11:57:00.000Z",
      phase: "before-send"
    })
    // A direct-only machine never seen has no age to report.
    const directOnly = link({
      machines: [],
      roster: [laptopRoute],
      direct: async () => Promise.reject(new DirectPathError("before-send", "refused"))
    })
    expect(
      (await failure(directOnly.machineLink.invoke("machine-laptop", "x", {}, origin))).message
    ).toBe("my laptop is offline")
  })

  it("says so when the target predates cross-machine calls", async () => {
    const { machineLink } = link({
      roster: [laptopRoute],
      direct: async () => ({ status: 404, body: '{"error":"Route not found"}' }),
      cloud: async () =>
        Promise.reject(new GatewayChannelError("before-send", "refused", "unsupported"))
    })
    const error = await failure(machineLink.invoke("machine-laptop", "x", {}, origin))
    expect(error.message).toBe(
      "Laptop runs a Codevisor version that can't take calls from other machines; update it"
    )
    expect(error.details).toMatchObject({ phase: "before-send" })
  })

  it("re-throws the target's own tool error unchanged", async () => {
    const nested = {
      message: "Phone is offline",
      code: "machine_unavailable",
      details: { machineId: "machine-phone", phase: "before-send" }
    }
    const { machineLink } = link({
      cloud: async () => ({ status: 422, body: JSON.stringify({ error: nested }) })
    })
    const error = await failure(machineLink.invoke("machine-laptop", "x", {}, origin))
    expect({ message: error.message, code: error.code, details: error.details }).toEqual(nested)

    const plain = link({
      cloud: async () => ({ status: 422, body: JSON.stringify({ error: { message: "bad" } }) })
    })
    const bare = await failure(plain.machineLink.invoke("machine-laptop", "x", {}, origin))
    expect([bare.message, bare.code, bare.details]).toEqual(["bad", undefined, undefined])
  })

  it.each([
    [{ status: 500, body: '{"error":"Internal"}' }, "Laptop answered HTTP 500: Internal"],
    [{ status: 502, body: "<html>" }, "Laptop answered HTTP 502"],
    [{ status: 200, body: "{}" }, "Laptop answered HTTP 200"]
  ])("turns an unexpected answer into a tool error", async (answer, message) => {
    const { machineLink } = link({ cloud: async () => answer })
    expect((await failure(machineLink.invoke("machine-laptop", "x", {}, origin))).message).toBe(
      message
    )
  })

  it("refuses unknown machines and calls to itself before sending anything", async () => {
    const { machineLink, sent } = link()
    const unknown = await failure(machineLink.invoke("nowhere", "x", {}, origin))
    expect(unknown.message).toBe('No machine "nowhere" on this account')
    expect(unknown.details).toEqual({
      machineId: "nowhere",
      name: "nowhere",
      lastSeen: null,
      phase: "before-send"
    })
    const self = await failure(machineLink.invoke("machine-self", "x", {}, origin))
    expect(self.code).toBeUndefined()
    expect(sent).toEqual({ direct: [], cloud: [], probes: 0 })
  })

  it("passes the caller's abort through untouched", async () => {
    const reason = new Error("aborted by caller")
    const direct = link({ roster: [laptopRoute], direct: async () => Promise.reject(reason) })
    await expect(direct.machineLink.invoke("machine-laptop", "x", {}, origin)).rejects.toBe(reason)
    const relay = link({ cloud: async () => Promise.reject(reason) })
    await expect(relay.machineLink.invoke("machine-laptop", "x", {}, origin)).rejects.toBe(reason)
  })
})

describe("relative ages", () => {
  it.each([
    ["2100-01-01T11:59:30.000Z", "just now"],
    ["2100-01-01T11:15:00.000Z", "45m ago"],
    ["2100-01-01T02:00:00.000Z", "10h ago"],
    ["2099-12-28T12:00:00.000Z", "4d ago"]
  ])("formats %s", (iso, expected) => {
    expect(relativeAge(iso, NOW)).toBe(expected)
  })
})
