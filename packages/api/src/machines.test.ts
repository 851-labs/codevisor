import { describe, expect, it } from "vitest"

import {
  FLEET_SESSION_EVENT_PATH,
  isFleetPath,
  parseRemoteSessionKey,
  remoteSessionKey
} from "./machines.js"

describe("remote session keys", () => {
  it.each([
    ["plain ids", "machine-a", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"],
    ["a machine id with colons", "cloud:device-1", "s-1"],
    ["a session id with colons", "machine-a", "thread:1:2"],
    ["percent signs", "machine%20a", "s%3A1"],
    ["the reserved no-session word as a real id", "machine-a", "none"]
  ])("round-trips %s", (_label, machineId, sessionId) => {
    expect(parseRemoteSessionKey(remoteSessionKey(machineId, sessionId))).toEqual({
      machineId,
      sessionId
    })
  })

  it("keeps the keys earlier versions stored for ordinary ids", () => {
    expect(remoteSessionKey("machine-a", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99")).toBe(
      "remote:machine-a:6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"
    )
    expect(remoteSessionKey("machine-a", undefined)).toBe("remote:machine-a:none")
    expect(parseRemoteSessionKey("remote:cloud:device-1:6cd8cdd5")).toEqual({
      machineId: "cloud:device-1",
      sessionId: "6cd8cdd5"
    })
  })

  it.each([
    ["a local session id", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"],
    ["a call without a session", remoteSessionKey("machine-a", undefined)],
    ["an earlier version's call without a session", "remote:cloud:device-1:none"],
    ["a key without a machine", "remote::s-1"],
    ["a key without a session", "remote:machine-a:"],
    ["a bare prefix", "remote:"],
    ["a malformed escape", "remote:machine-a:%E0%A4%A"],
    ["a malformed machine escape", "remote:%E0%A4%A:s-1"]
  ])("reads %s as no remote session", (_label, key) => {
    expect(parseRemoteSessionKey(key)).toBeUndefined()
  })
})

describe("fleet paths", () => {
  it("reserves the fleet namespace for machine-to-machine messages", () => {
    expect(isFleetPath(FLEET_SESSION_EVENT_PATH)).toBe(true)
    expect(isFleetPath("codevisor.sessions.create")).toBe(false)
  })
})
