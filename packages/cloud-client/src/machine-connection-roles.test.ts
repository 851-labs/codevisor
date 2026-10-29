import { CLOUD_PROTOCOL_VERSION, ROLES_FEATURE } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { harness } from "./machine-connection-test-support.js"
import { MachineRoles } from "./machine-roles.js"

const ROLE = "sandbox-manager"

const connectedRig = (features: string[] | undefined, icon?: string) => {
  const roles = new MachineRoles({ now: () => 0, scheduleTimeout: () => () => undefined })
  const h = harness({
    roles,
    device: { name: "vps", os: "linux", ...(icon === undefined ? {} : { icon }) }
  })
  roles.run(ROLE, () => undefined)
  h.connection.start()
  const socket = h.sockets.at(-1)!
  socket.onopen?.()
  socket.receive({
    t: "welcome",
    protocol: CLOUD_PROTOCOL_VERSION,
    connectionId: "conn-m",
    ...(features === undefined ? {} : { features })
  })
  return { h, roles, socket }
}

describe("machine connection roles", () => {
  it("joins its roles once the hub says it coordinates them", () => {
    const { socket } = connectedRig([ROLES_FEATURE], "laptopcomputer")

    expect(socket.sent.slice(1)).toEqual([
      { t: "role-members", availability: "portable", candidate: [ROLE], watch: [] }
    ])
  })

  it("sends no role frames to a hub that doesn't coordinate roles", () => {
    const { socket } = connectedRig(undefined)

    expect(socket.sent.map((frame) => frame.t)).toEqual(["hello"])
  })

  it("routes role frames to the roles and stops sending once the socket drops", () => {
    const { roles, socket } = connectedRig([ROLES_FEATURE])

    socket.receive({ t: "role-holders", roles: [{ role: ROLE, version: 1, holder: "machine-1" }] })
    expect(socket.sent.at(-1)).toMatchObject({ t: "role-renew", role: ROLE, version: 1 })
    socket.onclose?.(1006)
    roles.receive({ t: "role-holders", roles: [{ role: ROLE, version: 2, holder: "machine-1" }] })

    expect(socket.sent.filter((frame) => frame.t === "role-renew")).toHaveLength(1)
    expect(roles.views()).toEqual([{ role: ROLE, version: 2, holder: "machine-1", held: false }])
  })
})
