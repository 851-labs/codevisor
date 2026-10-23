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
    ["the word earlier versions used for no session", "machine-a", "none"]
  ])("round-trips %s", (_label, machineId, sessionId) => {
    expect(parseRemoteSessionKey(remoteSessionKey(machineId, sessionId))).toEqual({
      machineId,
      sessionId
    })
  })

  it("marks the encoded form with its own prefix", () => {
    expect(remoteSessionKey("cloud:device-1", "s:1")).toBe("remote2:cloud%3Adevice-1:s%3A1")
    expect(remoteSessionKey("machine-a", undefined)).toBe("remote2:machine-a:")
  })

  it.each([
    ["an ordinary key", "remote:machine-a:6cd8cdd5", "machine-a", "6cd8cdd5"],
    ["a machine id with colons", "remote:cloud:device-1:6cd8cdd5", "cloud:device-1", "6cd8cdd5"],
    ["percent signs, kept as written", "remote:machine%20a:s%3A1", "machine%20a", "s%3A1"]
  ])("reads an earlier version's key with %s literally", (_label, key, machineId, sessionId) => {
    expect(parseRemoteSessionKey(key)).toEqual({ machineId, sessionId })
  })

  it.each([
    ["a local session id", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"],
    ["a call without a session", remoteSessionKey("machine-a", undefined)],
    ["an earlier version's call without a session", "remote:cloud:device-1:none"],
    ["an earlier version's key without a machine", "remote::s-1"],
    ["an earlier version's bare prefix", "remote:"],
    ["an encoded key without a machine", "remote2::s-1"],
    ["an encoded key with an extra part", "remote2:machine-a:s:1"],
    ["a malformed session escape", "remote2:machine-a:%E0%A4%A"],
    ["a malformed machine escape", "remote2:%E0%A4%A:s-1"]
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
