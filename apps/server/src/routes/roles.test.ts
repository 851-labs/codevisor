import { MachineRoles } from "@codevisor/cloud-client"
import { describe, expect, it } from "vitest"

import type { CloudServerControl } from "../server-context-types.js"
import { makeServices, start, startWithApp } from "../test-support.js"

const ROLE = "sandbox-manager"

const cloudStatus = {
  roles: [
    {
      role: ROLE,
      version: 3,
      holder: "device-1",
      leaseExpiresAt: "2026-10-29T12:00:30.000Z",
      candidates: [
        {
          deviceId: "device-1",
          name: "Studio",
          availability: "always-on",
          online: true,
          onlineSince: "2026-10-29T11:00:00.000Z",
          recentDrops: 0,
          rank: 1
        }
      ]
    }
  ]
}

const cloudControl = (
  machineRequest: CloudServerControl["machineRequest"]
): CloudServerControl => ({
  deviceId: () => "device-1",
  state: () => "connected",
  managedBy: () => "app",
  connect: async () => "device-1",
  disconnect: async () => ({ removedFromAccount: false }),
  ...(machineRequest === undefined ? {} : { machineRequest })
})

const watchedRoles = () => {
  const roles = new MachineRoles({ now: () => 0, scheduleTimeout: () => () => undefined })
  roles.watch(ROLE, () => undefined)
  roles.receive({ t: "role-holders", roles: [{ role: ROLE, version: 3, holder: "device-1" }] })
  return roles
}

describe("roles route", () => {
  it("serves this machine's role views alongside the cloud coordinator's", async () => {
    const requests: string[] = []
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, machineRoles: watchedRoles() }, undefined, {
      cloud: cloudControl(async (method, path) => {
        requests.push(`${method} ${path}`)
        return cloudStatus
      })
    })

    const response = await fetch(`${server.url}/v1/roles`)

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      machineId: "device-1",
      roles: [{ role: ROLE, version: 3, holder: "device-1", held: false }],
      cloud: cloudStatus.roles
    })
    expect(requests).toEqual(["GET /api/machine/roles"])
  })

  it("still serves the local view when the cloud can't answer", async () => {
    const { services } = await makeServices("server-a")
    const offline = await startWithApp({ ...services, machineRoles: watchedRoles() })
    const failing = await startWithApp({ ...services, machineRoles: watchedRoles() }, undefined, {
      cloud: cloudControl(async () => {
        throw new Error("Cloud request failed (502): bad gateway")
      })
    })

    expect(await (await fetch(`${offline.url}/v1/roles`)).json()).toMatchObject({
      roles: [{ role: ROLE }],
      cloudError: "This machine isn't connected to Codevisor Cloud"
    })
    expect(await (await fetch(`${failing.url}/v1/roles`)).json()).toMatchObject({
      roles: [{ role: ROLE }],
      cloudError: "Cloud request failed (502): bad gateway"
    })
    const rejecting = await startWithApp({ ...services, machineRoles: watchedRoles() }, undefined, {
      cloud: cloudControl(() => Promise.reject("relay unreachable"))
    })
    expect(await (await fetch(`${rejecting.url}/v1/roles`)).json()).toMatchObject({
      cloudError: "relay unreachable"
    })
  })

  it("reports roles unavailable without a roles service", async () => {
    const { server } = await start()
    expect((await fetch(`${server.url}/v1/roles`)).status).toBe(501)
    expect((await fetch(`${server.url}/v1/roles`, { method: "POST" })).status).toBe(404)
  })
})
