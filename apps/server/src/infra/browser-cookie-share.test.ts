import {
  browserCookieKey,
  BrowserCookieSnapshot,
  decode,
  FLEET_BROWSER_COOKIES_PATH,
  FLEET_CALLER_HEADER,
  type BrowserCookie,
  type MachineSummary
} from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import {
  laptop,
  postInvoke,
  resultOf,
  stranger,
  studio,
  type Member
} from "../routes/fleet-test-support.js"
import {
  defaultServerConfig,
  startCodevisorServer,
  type RunningCodevisorServer
} from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"
import {
  browserCookieCatchUpMs,
  browserCookieSharePollMs,
  makeBrowserCookieShare,
  type BrowserCookieShare
} from "./browser-cookie-share.js"
import { makeFleetTickets, withTicket, type FleetTickets } from "./fleet-tickets.js"
import type { MachineLink } from "./machine-link.js"

interface SharingMachine {
  readonly member: Member
  readonly server: RunningCodevisorServer
  readonly fleetTickets: FleetTickets
  readonly share: BrowserCookieShare
}

interface Fleet {
  readonly machines: Map<string, SharingMachine>
  readonly sandboxes: Set<string>
}

const members = [studio, laptop]
const quietFleet: Fleet = { machines: new Map(), sandboxes: new Set() }

const cookie = (domain: string, name: string, value: string): BrowserCookie => ({
  name,
  value,
  domain,
  path: "/",
  httpOnly: true,
  secure: true,
  sameSite: "lax"
})

const startFleet = async (sandboxes: ReadonlyArray<string> = []) => {
  const fleet: Fleet = { machines: new Map(), sandboxes: new Set(sandboxes) }
  return {
    studio: await startMachine(studio, fleet),
    laptop: await startMachine(laptop, fleet)
  }
}

const startMachine = async (self: Member, fleet: Fleet): Promise<SharingMachine> => {
  const made = await makeServices(self.id)
  const fleetTickets = makeFleetTickets()
  const link = fleetLink(self, fleet)
  const share = makeBrowserCookieShare({
    db: made.services.db,
    link,
    self: { id: self.id, name: () => self.name },
    isSandbox: () => fleet.sandboxes.has(self.id),
    now: () => 0,
    log: () => undefined
  })
  const services = { ...made.services, machines: link, fleetTickets, browserCookieShare: share }
  const server = await run(
    startCodevisorServer(
      services,
      defaultServerConfig({ bootId: "test-boot", id: self.id, port: 0 })
    )
  )
  runningServers.push(server)
  const machine = { member: self, server, fleetTickets, share }
  fleet.machines.set(self.id, machine)
  return machine
}

const fleetLink = (self: Member, fleet: Fleet): MachineLink => ({
  list: async () => members.map((member) => summary(member, self, fleet)),
  resolve: (machine) => {
    const member = members.find((candidate) => candidate.id === machine)
    if (member === undefined || member.id === self.id) return undefined
    return {
      id: member.id,
      name: member.name,
      deviceId: member.id,
      isSandbox: fleet.sandboxes.has(member.id)
    }
  },
  isGone: () => false,
  machineIdOf: (caller) =>
    members.find((member) => member.id === caller.deviceId && member.publicKey === caller.publicKey)
      ?.id,
  invoke: async (machine, path, args, origin) => {
    const answer = await callAs(self, fleet.machines.get(machine)!, { path, args, origin })
    if (answer.status !== 200) throw new Error(JSON.stringify(answer.body))
    return resultOf(answer.body)
  }
})

const summary = (member: Member, self: Member, fleet: Fleet): MachineSummary => ({
  id: member.id,
  name: member.name,
  online: true,
  isCurrent: member.id === self.id,
  ...(fleet.sandboxes.has(member.id)
    ? { ephemeral: { provider: "modal", ownerDeviceId: laptop.id } }
    : {})
})

const callAs = (caller: Member, target: SharingMachine, body: unknown) =>
  withTicket(
    target.fleetTickets.callers,
    { deviceId: caller.id, publicKey: caller.publicKey },
    (ticket) => postInvoke(target.server.url, body, { [FLEET_CALLER_HEADER]: ticket })
  )

const shareRequest = (from: Member) => ({
  path: FLEET_BROWSER_COOKIES_PATH,
  args: { since: 0, entries: [] },
  origin: { machineId: from.id, machineName: from.name }
})

const exchange = (machine: SharingMachine, mutations: unknown[] = []) =>
  jsonRequest(machine.server, "/v1/browser/state/cookies", {
    method: "POST",
    body: JSON.stringify({ mutations })
  })

const signIn = (machine: SharingMachine, ...cookies: BrowserCookie[]) =>
  exchange(
    machine,
    cookies.map((value) => ({ key: browserCookieKey(value), expectedRevision: 0, cookie: value }))
  )

const jar = async (machine: SharingMachine): Promise<Record<string, string>> => {
  const snapshot = decode(BrowserCookieSnapshot)((await exchange(machine)).body)
  return Object.fromEntries(
    snapshot.entries.flatMap((entry) =>
      entry.cookie === null
        ? []
        : [[`${entry.cookie.domain} ${entry.cookie.name}`, entry.cookie.value]]
    )
  )
}

describe("shared browser cookie jar", () => {
  it("brings a sign-in to the other machine and keeps local hosts where they are", async () => {
    const fleet = await startFleet()
    await signIn(
      fleet.laptop,
      cookie(".github.com", "user_session", "laptop"),
      cookie("localhost", "dev_session", "laptop-dev")
    )

    await fleet.laptop.share.shareNow()

    expect(await jar(fleet.studio)).toEqual({ ".github.com user_session": "laptop" })
  })

  it("replaces a whole site on every machine when Chrome is imported", async () => {
    const fleet = await startFleet()
    await signIn(fleet.studio, cookie(".github.com", "old_session", "studio"))
    await fleet.studio.share.shareNow()

    const imported = await jsonRequest(fleet.laptop.server, "/v1/browser/state/cookies/import", {
      method: "POST",
      body: JSON.stringify({ cookies: [cookie(".github.com", "user_session", "chrome")] })
    })
    await fleet.laptop.share.shareNow()

    expect(imported.body).toEqual({ imported: 1, replaced: 1 })
    expect(await jar(fleet.studio)).toEqual({ ".github.com user_session": "chrome" })
  })

  it("never trades cookies with sandboxes or machines outside the account", async () => {
    const fleet = await startFleet([studio.id])
    await signIn(fleet.studio, cookie(".github.com", "user_session", "sandbox"))
    await signIn(fleet.laptop, cookie(".github.com", "user_session", "laptop"))

    await fleet.studio.share.shareNow()
    await fleet.laptop.share.shareNow()

    expect((await callAs(studio, fleet.laptop, shareRequest(studio))).status).toBe(403)
    expect((await callAs(stranger, fleet.laptop, shareRequest(stranger))).status).toBe(403)
    expect(await jar(fleet.laptop)).toEqual({ ".github.com user_session": "laptop" })
    expect(await jar(fleet.studio)).toEqual({ ".github.com user_session": "sandbox" })
  })

  it("shares shortly after a local change and catches up once a minute", async () => {
    const { services } = await makeServices(laptop.id)
    const shared: string[] = []
    let clock = 0
    const share = makeBrowserCookieShare({
      db: services.db,
      link: {
        list: async () => members.map((member) => summary(member, laptop, quietFleet)),
        resolve: () => undefined,
        invoke: async (machine) => {
          shared.push(machine)
          return { revision: 0, more: false, entries: [] }
        }
      },
      self: { id: laptop.id, name: () => laptop.name },
      isSandbox: () => false,
      now: () => clock,
      log: () => undefined
    })
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    try {
      share.start()
      await vi.advanceTimersByTimeAsync(browserCookieSharePollMs * 2)
      expect(shared).toEqual([studio.id])

      await run(
        services.db.exchangeBrowserCookies([
          {
            key: browserCookieKey(cookie("github.com", "s", "v")),
            expectedRevision: 0,
            cookie: cookie("github.com", "s", "v")
          }
        ])
      )
      await vi.advanceTimersByTimeAsync(browserCookieSharePollMs)
      expect(shared).toEqual([studio.id, studio.id])

      clock = browserCookieCatchUpMs
      await vi.advanceTimersByTimeAsync(browserCookieSharePollMs)
      expect(shared).toEqual([studio.id, studio.id, studio.id])
    } finally {
      share.stop()
      vi.useRealTimers()
    }
  })
})
