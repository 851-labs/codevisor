import { ROLE_RENEW_MS, type MachineToHub } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { ROLE_CLOCK_MARGIN_MS } from "./machine-role-lease.js"
import { MachineRoles, type HeldRole, type RoleView } from "./machine-roles.js"

const ROLE = "sandbox-manager"
const LEASE_MS = 30_000
const SELF = "machine-a"
const OTHER = "machine-b"

class ManualClock {
  time = 0
  readonly #timers: { at: number; callback: () => void; cancelled: boolean }[] = []

  readonly now = (): number => this.time

  readonly scheduleTimeout = (callback: () => void, delayMs: number) => {
    const timer = { at: this.time + delayMs, callback, cancelled: false }
    this.#timers.push(timer)
    return () => {
      timer.cancelled = true
    }
  }

  advanceTo(time: number): void {
    for (;;) {
      const due = this.#timers
        .filter((timer) => !timer.cancelled && timer.at <= time)
        .toSorted((first, second) => first.at - second.at)[0]
      if (due === undefined) break
      due.cancelled = true
      this.time = due.at
      due.callback()
    }
    this.time = time
  }
}

const rig = (log?: (line: string) => void) => {
  const clock = new ManualClock()
  const sent: MachineToHub[] = []
  const roles = new MachineRoles({
    now: clock.now,
    scheduleTimeout: clock.scheduleTimeout,
    ...(log === undefined ? {} : { log })
  })
  const attach = () =>
    roles.attach({
      deviceId: SELF,
      availability: "always-on",
      send: (frame) => {
        sent.push(frame)
        return true
      }
    })
  const lastRenew = () => {
    const renew = sent.findLast((frame) => frame.t === "role-renew")
    if (renew?.t !== "role-renew") throw new Error("expected a renew frame")
    return renew
  }
  const holders = (version: number, holder?: string) =>
    roles.receive({
      t: "role-holders",
      roles: [{ role: ROLE, version, ...(holder === undefined ? {} : { holder }) }]
    })
  const ack = (held = true) => {
    const renew = lastRenew()
    roles.receive({
      t: "role-lease",
      role: ROLE,
      version: renew.version,
      seq: renew.seq,
      held,
      leaseMs: LEASE_MS
    })
  }
  return { clock, sent, roles, attach, lastRenew, holders, ack }
}

const runRole = (roles: MachineRoles) => {
  const leases: HeldRole[] = []
  const stop = roles.run(ROLE, (lease) => {
    leases.push(lease)
  })
  return { leases, stop }
}

describe("machine roles", () => {
  it("joins as a candidate and starts its task only once the hub confirms the lease", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()

    expect(h.sent).toEqual([
      { t: "role-members", availability: "always-on", candidate: [ROLE], watch: [] }
    ])
    h.holders(1, SELF)
    expect(h.lastRenew()).toMatchObject({ role: ROLE, version: 1 })
    expect(h.roles.holding(ROLE)).toBeUndefined()

    h.ack()

    expect(leases.map((lease) => lease.fence)).toEqual([{ role: ROLE, version: 1 }])
    expect(h.roles.holding(ROLE)?.version).toBe(1)
  })

  it("keeps renewing and stops acting before the hub could hand the role to someone else", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    h.clock.advanceTo(ROLE_RENEW_MS)
    expect(h.lastRenew().seq).toBe(2)
    h.ack()
    h.clock.advanceTo(ROLE_RENEW_MS * 2)
    expect(h.lastRenew().seq).toBe(3)

    h.clock.advanceTo(ROLE_RENEW_MS + LEASE_MS - ROLE_CLOCK_MARGIN_MS - 1)
    expect(leases[0]?.held()).toBe(true)
    h.clock.advanceTo(ROLE_RENEW_MS + LEASE_MS - ROLE_CLOCK_MARGIN_MS)
    expect(leases[0]?.signal.aborted).toBe(true)
    expect(leases[0]?.held()).toBe(false)
  })

  it("measures the lease from when the renewal was sent, not when the slow reply arrived", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.clock.advanceTo(5_000)
    h.ack()

    h.clock.advanceTo(LEASE_MS - ROLE_CLOCK_MARGIN_MS)
    expect(leases[0]?.held()).toBe(false)
  })

  it("aborts the task when the hub hands the role to another machine", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    h.holders(2, OTHER)

    expect(leases[0]?.signal.aborted).toBe(true)
    expect(h.roles.views()).toEqual([{ role: ROLE, version: 2, holder: OTHER, held: false }])
  })

  it("releases at once when the hub asks it to hand off", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    h.roles.receive({ t: "role-lease", role: ROLE, version: 1, held: false, leaseMs: LEASE_MS })

    expect(leases[0]?.signal.aborted).toBe(true)
    expect(h.sent.at(-1)).toEqual({ t: "role-release", role: ROLE, version: 1 })
  })

  it("withdraws its candidacy before releasing when its task stops running", () => {
    const h = rig()
    const { leases, stop } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    stop()

    expect(leases[0]?.signal.aborted).toBe(true)
    expect(h.sent.slice(-2)).toEqual([
      { t: "role-members", availability: "always-on", candidate: [], watch: [] },
      { t: "role-release", role: ROLE, version: 1 }
    ])
  })

  it("rides out a short disconnect by renewing as soon as it reconnects", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    h.roles.detach()
    h.clock.advanceTo(ROLE_RENEW_MS + 1)
    const renewsWhileAway = h.sent.filter((frame) => frame.t === "role-renew").length
    h.attach()
    h.ack()

    expect(renewsWhileAway).toBe(1)
    expect(h.lastRenew()).toMatchObject({ version: 1 })
    expect(leases).toHaveLength(1)
    expect(leases[0]?.held()).toBe(true)
  })

  it("tells watchers who holds a role without running for it", () => {
    const h = rig()
    const seen: RoleView[] = []
    h.roles.watch(ROLE, (view) => seen.push(view))
    h.attach()

    h.holders(4, OTHER)

    expect(h.sent).toEqual([
      { t: "role-members", availability: "always-on", candidate: [], watch: [ROLE] }
    ])
    expect(seen).toEqual([{ role: ROLE, version: 4, holder: OTHER, held: false }])
    expect(h.sent.some((frame) => frame.t === "role-renew")).toBe(false)
  })

  it("starts a task that joins while the role is held and keeps the lease until the last task stops", () => {
    const h = rig()
    const first = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    const second = runRole(h.roles)
    second.stop()

    expect(second.leases.map((lease) => lease.version)).toEqual([1])
    expect(first.leases[0]?.signal.aborted).toBe(false)
    expect(h.sent.at(-1)).toEqual({
      t: "role-members",
      availability: "always-on",
      candidate: [ROLE],
      watch: []
    })
  })

  it("withdraws without a release when it never held the role", () => {
    const h = rig()
    const { stop } = runRole(h.roles)
    h.attach()

    stop()

    expect(h.sent.map((frame) => frame.t)).toEqual(["role-members", "role-members"])
  })

  it("ignores an acknowledgement that arrives after its task stopped", () => {
    const h = rig()
    const { leases, stop } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    stop()

    h.ack()

    expect(leases).toEqual([])
    expect(h.roles.holding(ROLE)).toBeUndefined()
  })

  it("ignores frames for roles it never joined and leases it never asked for", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()

    h.roles.receive({ t: "role-holders", roles: [{ role: "scheduled-tasks", version: 1 }] })
    h.roles.receive({
      t: "role-lease",
      role: "scheduled-tasks",
      version: 1,
      held: true,
      leaseMs: 1
    })
    h.roles.receive({ t: "role-lease", role: ROLE, version: 1, held: true, leaseMs: LEASE_MS })
    h.roles.receive({ t: "role-lease", role: ROLE, version: 1, seq: 99, held: true, leaseMs: 1 })

    expect(leases).toEqual([])
    expect(h.roles.views()).toEqual([{ role: ROLE, version: 0, held: false }])
  })

  it("logs a task that fails without giving up the lease", async () => {
    let logged!: (line: string) => void
    const failure = new Promise<string>((resolve) => {
      logged = resolve
    })
    const h = rig((line) => logged(line))
    h.roles.run(ROLE, async () => {
      throw new Error("provider unreachable")
    })
    h.attach()
    h.holders(1, SELF)
    h.ack()

    expect(await failure).toBe(`Role ${ROLE} task failed: Error: provider unreachable`)
    expect(h.roles.holding(ROLE)?.version).toBe(1)
  })

  it("stops watching and never claims a role it only watches", () => {
    const h = rig()
    const stop = h.roles.watch(ROLE, () => undefined)
    h.attach()

    h.holders(4, SELF)
    stop()

    expect(h.sent.map((frame) => frame.t)).toEqual(["role-members", "role-members"])
    expect(h.sent.at(-1)).toEqual({
      t: "role-members",
      availability: "always-on",
      candidate: [],
      watch: []
    })
  })

  it("runs for a role it also watches as a candidate, not a watcher", () => {
    const h = rig()
    h.roles.watch(ROLE, () => undefined)
    runRole(h.roles)
    h.attach()

    expect(h.sent).toEqual([
      { t: "role-members", availability: "always-on", candidate: [ROLE], watch: [] }
    ])
  })

  it("restarts its task under the new version when the hub re-grants the role to it", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(1, SELF)
    h.ack()

    h.holders(2, SELF)
    expect(leases[0]?.signal.aborted).toBe(true)
    expect(h.lastRenew().version).toBe(2)
    h.ack()

    expect(leases.map((lease) => lease.fence.version)).toEqual([1, 2])
  })

  it("keeps its lease when the hub refuses a renewal for an older version", () => {
    const h = rig()
    const { leases } = runRole(h.roles)
    h.attach()
    h.holders(2, SELF)
    h.ack()

    h.roles.receive({ t: "role-lease", role: ROLE, version: 1, held: false, leaseMs: LEASE_MS })

    expect(leases[0]?.held()).toBe(true)
  })
})
