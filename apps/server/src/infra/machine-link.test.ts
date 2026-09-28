import type { CloudMachinePresence } from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"
import { GatewayChannelError, type GatewayExchange } from "@codevisor/cloud-client"
import { describe, expect, it } from "vitest"

import { makeMachineLink, relativeAge, type MachineLinkCloud } from "./machine-link.js"

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

const ok = (result: unknown): GatewayExchange => ({ status: 200, body: JSON.stringify({ result }) })

/// A link over scripted paths; each path records the bodies it was asked to
/// deliver so tests can prove what did (and did not) get sent.
const link = (
  options: {
    machines?: CloudMachinePresence[] | undefined
    cloud?: (deviceId: string) => Promise<GatewayExchange>
  } = {}
) => {
  const sent = { cloud: [] as unknown[] }
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

describe("machine list", () => {
  it("merges this machine and hub presence under stable ids", async () => {
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
      ]
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
      }
    ])
  })
})

describe("machine list without hub presence", () => {
  it("lists only this machine before the hub reports peers", async () => {
    const { machineLink } = link({ machines: undefined })
    expect(await machineLink.list()).toEqual([
      { id: "machine-self", name: "Studio", os: "darwin", online: true, isCurrent: true }
    ])
  })
})

describe("machine calls", () => {
  it("sends the call with its origin over the relay", async () => {
    const { machineLink, sent } = link()
    expect(
      await machineLink.invoke("machine-laptop", "xcode.build", { scheme: "App" }, origin)
    ).toBe("via cloud")
    expect(sent.cloud).toEqual([{ path: "xcode.build", args: { scheme: "App" }, origin }])
  })

  it("resolves machines by case-insensitive name", async () => {
    const { machineLink } = link()
    expect(await machineLink.invoke("LAPTOP", "search", {}, origin)).toBe("via cloud")
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
  })

  it("says so when the target predates cross-machine calls", async () => {
    const { machineLink } = link({
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
    expect((await failure(machineLink.invoke("studio", "x", {}, origin))).message).toBe(
      "Studio is the current machine; call its tools directly"
    )
    expect(sent).toEqual({ cloud: [] })
  })

  it("passes the caller's abort through untouched", async () => {
    const reason = new Error("aborted by caller")
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
