import { describe, expect, it } from "vitest"

import type { RoleAvailability } from "./cloud-role-protocol.js"
import {
  electRole,
  nextRoleCheck,
  releaseRole,
  renewRole,
  roleHolder,
  ROLE_LEASE_MS,
  ROLE_STABLE_MS,
  VACANT_ROLE,
  type RoleCandidate,
  type RoleRanking,
  type RoleState
} from "./role-election.js"
import { makeRoleFence } from "./role-fence.js"

const candidate = (
  deviceId: string,
  availability: RoleAvailability,
  onlineSince = 0,
  recentDrops = 0
): RoleCandidate => ({ deviceId, availability, onlineSince, recentDrops })

const laptop = candidate("laptop", "portable")
const desktop = candidate("desktop", "always-on")
const sandbox = candidate("sandbox", "ephemeral")

describe("role election", () => {
  it("prefers always-on machines, then fewer recent drops, then longer uptime", () => {
    const flaky = candidate("flaky", "always-on", 0, 4)
    const steady = candidate("steady", "always-on", 500, 0)
    const veteran = candidate("veteran", "always-on", 100, 0)

    expect(roleHolder(electRole(VACANT_ROLE, [sandbox, laptop, desktop], 1_000), 1_000)).toBe(
      "desktop"
    )
    expect(roleHolder(electRole(VACANT_ROLE, [flaky, steady, veteran], 1_000), 1_000)).toBe(
      "veteran"
    )
    expect(roleHolder(electRole(VACANT_ROLE, [sandbox], 1_000), 1_000)).toBe("sandbox")
    expect(roleHolder(electRole(VACANT_ROLE, [candidate("b", "portable"), laptop], 0), 0)).toBe("b")
  })

  it("leaves a role vacant without candidates and bumps the version on every grant", () => {
    const vacant = electRole(VACANT_ROLE, [], 0)
    const first = electRole(vacant, [laptop], 0)
    const regranted = electRole(first, [laptop], ROLE_LEASE_MS)

    expect(vacant).toEqual({ version: 0 })
    expect(first.version).toBe(1)
    expect(regranted).toMatchObject({ version: 2, lease: { holder: "laptop" } })
  })

  it("uses a pluggable ranking", () => {
    const byName: RoleRanking = {
      compare: (first, second) => second.deviceId.localeCompare(first.deviceId),
      preempts: () => false
    }

    expect(roleHolder(electRole(VACANT_ROLE, [desktop, laptop], 0, byName), 0)).toBe("laptop")
  })
})

describe("role leases", () => {
  it("keeps the holder while it renews and fails over once its lease lapses", () => {
    const held = electRole(VACANT_ROLE, [desktop, laptop], 0)
    const renewed = renewRole(held, "desktop", held.version, ROLE_LEASE_MS - 1)
    const kept = electRole(renewed.state, [desktop, laptop], ROLE_LEASE_MS + 1)
    const lapsed = electRole(kept, [desktop, laptop], 2 * ROLE_LEASE_MS)

    expect(renewed.held).toBe(true)
    expect(roleHolder(kept, ROLE_LEASE_MS + 1)).toBe("desktop")
    expect(lapsed).toMatchObject({ version: 2, lease: { holder: "laptop" } })
  })

  it("keeps an offline holder's lease until it lapses so it can't overlap a successor", () => {
    const held = electRole(VACANT_ROLE, [desktop, laptop], 0)

    expect(roleHolder(electRole(held, [laptop], ROLE_LEASE_MS - 1), ROLE_LEASE_MS - 1)).toBe(
      "desktop"
    )
    expect(roleHolder(electRole(held, [laptop], ROLE_LEASE_MS), ROLE_LEASE_MS)).toBe("laptop")
  })

  it("hands the role on straight away when the holder releases it", () => {
    const held = electRole(VACANT_ROLE, [desktop, laptop], 0)
    const released = releaseRole(held, "desktop", held.version)

    expect(electRole(released, [laptop], 1)).toMatchObject({
      version: 2,
      lease: { holder: "laptop" }
    })
    expect(releaseRole(held, "laptop", held.version)).toBe(held)
    expect(releaseRole(held, "desktop", held.version - 1)).toBe(held)
  })

  it("refuses renewals from anyone but the current holder and version", () => {
    const held = electRole(VACANT_ROLE, [desktop, laptop], 0)

    expect(renewRole(held, "laptop", held.version, 1).held).toBe(false)
    expect(renewRole(held, "desktop", held.version + 1, 1).held).toBe(false)
    expect(renewRole(held, "desktop", held.version, ROLE_LEASE_MS).held).toBe(false)
  })

  it("re-grants a lapsed holder with a new version when nobody else can take the role", () => {
    const held = electRole(VACANT_ROLE, [laptop], 0)
    const regranted = electRole(held, [laptop], ROLE_LEASE_MS)

    expect(regranted).toMatchObject({ version: 2, lease: { holder: "laptop" } })
    expect(renewRole(regranted, "laptop", held.version, ROLE_LEASE_MS).held).toBe(false)
  })
})

describe("role preemption", () => {
  const heldByLaptop: RoleState = {
    version: 1,
    lease: { holder: "laptop", deadline: 10 * ROLE_STABLE_MS, handingOff: false }
  }

  it("moves the role to a better machine only after it has stayed online for the stable window", () => {
    const returning = candidate("desktop", "always-on", 10)
    const settles = 10 + ROLE_STABLE_MS
    const early = electRole(heldByLaptop, [laptop, returning], settles - 1)
    const settled = electRole(early, [laptop, returning], settles)
    const handedOff = electRole(releaseRole(settled, "laptop", 1), [laptop, returning], settles)

    expect(early).toBe(heldByLaptop)
    expect(nextRoleCheck(heldByLaptop, [laptop, returning], settles - 1)).toBe(settles)
    expect(settled.lease).toMatchObject({ holder: "laptop", handingOff: true })
    expect(renewRole(settled, "laptop", 1, settles).held).toBe(false)
    expect(handedOff).toMatchObject({ version: 2, lease: { holder: "desktop" } })
    expect(electRole(settled, [laptop, returning], settles + 1)).toBe(settled)
    expect(nextRoleCheck(settled, [laptop, returning], settles)).toBe(10 * ROLE_STABLE_MS)
    expect(nextRoleCheck(VACANT_ROLE, [laptop, returning], settles)).toBeUndefined()
  })

  it("never preempts within the same availability tier", () => {
    const steadier = candidate("desktop", "portable", 0, 0)
    const flakyLaptop = candidate("laptop", "portable", 0, 3)

    expect(electRole(heldByLaptop, [flakyLaptop, steadier], ROLE_STABLE_MS)).toBe(heldByLaptop)
    expect(nextRoleCheck(heldByLaptop, [flakyLaptop, steadier], 0)).toBe(10 * ROLE_STABLE_MS)
  })
})

describe("role flapping", () => {
  it("keeps the role on a steady holder while a better machine keeps reconnecting", () => {
    let state: RoleState = electRole(VACANT_ROLE, [laptop], 0)
    let now = 0
    for (let reconnect = 0; reconnect < 20; reconnect += 1) {
      now += ROLE_LEASE_MS / 3
      const flapping = candidate("desktop", "always-on", now - 1_000, reconnect)
      state = renewRole(
        electRole(state, [laptop, flapping], now),
        "laptop",
        state.version,
        now
      ).state
      state = electRole(state, [laptop], now + 1)
    }

    expect(state).toMatchObject({ version: 1, lease: { holder: "laptop", handingOff: false } })
  })

  it("does not hand the role back to a flapping holder that comes back within its own lease", () => {
    const held = electRole(VACANT_ROLE, [desktop, laptop], 0)
    const failedOver = electRole(held, [laptop], ROLE_LEASE_MS)
    const back = candidate("desktop", "always-on", ROLE_LEASE_MS + 5, 1)

    expect(electRole(failedOver, [laptop, back], ROLE_LEASE_MS + 10)).toBe(failedOver)
  })
})

describe("split-brain fencing", () => {
  it("rejects a stale holder's actions after a handoff", () => {
    const fence = makeRoleFence()
    const stale = electRole(VACANT_ROLE, [desktop, laptop], 0)
    const successor = electRole(stale, [laptop], ROLE_LEASE_MS)

    expect(fence.admit({ role: "sandbox-manager", version: stale.version })).toBe(true)
    expect(fence.admit({ role: "sandbox-manager", version: successor.version })).toBe(true)
    expect(fence.admit({ role: "sandbox-manager", version: stale.version })).toBe(false)
    expect(fence.admit({ role: "scheduled-tasks", version: stale.version })).toBe(true)
    expect(fence.highest("sandbox-manager")).toBe(successor.version)
  })

  it("never lets a partitioned holder renew back into a role someone else now holds", () => {
    const stale = electRole(VACANT_ROLE, [desktop, laptop], 0)
    const successor = electRole(stale, [laptop], ROLE_LEASE_MS)

    expect(renewRole(successor, "desktop", stale.version, ROLE_LEASE_MS + 1).held).toBe(false)
    expect(releaseRole(successor, "desktop", stale.version)).toBe(successor)
  })
})
