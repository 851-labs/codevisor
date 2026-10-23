import { describe, expect, it } from "vitest"

import {
  FLEET_SESSION_EVENT_PATH,
  isFleetPath,
  parseRemoteSessionKey,
  remoteSessionKey
} from "./machines.js"

describe("remote session keys", () => {
  it("round-trips machine ids that contain colons", () => {
    const key = remoteSessionKey("cloud:device-1", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99")

    expect(key).toBe("remote:cloud:device-1:6cd8cdd5-fbd6-40f2-b451-9d3e3378db99")
    expect(parseRemoteSessionKey(key)).toEqual({
      machineId: "cloud:device-1",
      sessionId: "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"
    })
  })

  it.each([
    ["a local session id", "6cd8cdd5-fbd6-40f2-b451-9d3e3378db99"],
    ["a call without a session", remoteSessionKey("machine-a", undefined)],
    ["a key without a machine", "remote::s-1"],
    ["a key without a session", "remote:machine-a:"]
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
