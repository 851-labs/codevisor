import { FLEET_CALLER_HEADER, SANDBOX_MANAGER_ROLE, type Sandbox } from "@codevisor/api"
import type { HeldRole } from "@codevisor/cloud-client"

import type { RunningCodevisorServer } from "../server.js"
import { startWithApp } from "../test-support.js"
import { isRecord } from "../unknown-values.js"
import { makeFleetTickets, withTicket, type FleetTickets } from "./fleet-tickets.js"
import { PeerAnswerError } from "./machine-link.js"
import { makeSandboxManagement } from "./sandbox-manager-link.js"
import {
  OWNER,
  presence,
  sandboxHarness,
  type SandboxHarnessOptions
} from "./sandbox-test-support.js"

export type Harness = Awaited<ReturnType<typeof sandboxHarness>>

export interface Member {
  readonly serverId: string
  readonly deviceId: string
}

export const laptop: Member = { serverId: "server-owner", deviceId: OWNER }
export const studio: Member = { serverId: "server-studio", deviceId: "device-studio" }

export interface Fleet {
  holder: string | undefined
  hostLocal: boolean
  readonly laptop: Machine
  readonly studio: Machine
}

export interface Machine {
  readonly harness: Harness
  readonly server: RunningCodevisorServer
}

export const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

export const startTwoMachines = async (options: SandboxHarnessOptions = {}): Promise<Fleet> => {
  const servers = new Map<string, { server: RunningCodevisorServer; tickets: FleetTickets }>()
  const fleet = { holder: studio.deviceId as string | undefined, hostLocal: false }
  const first = await machineFor(laptop, fleet, servers, options)
  first.harness.presences.push(presence(studio.deviceId, { serverId: studio.serverId }))
  const second = await machineFor(studio, fleet, servers, {
    ...options,
    owner: studio.deviceId,
    sharing: {
      provider: first.harness.provider,
      presences: first.harness.presences,
      workspaces: first.harness.workspaces
    }
  })
  return Object.assign(fleet, { laptop: first, studio: second })
}

export const syncRecords = async (from: Harness, to: Harness): Promise<void> => {
  const ids = (await from.records.list()).map((machine) => machine.id)
  await to.records.merge(await Promise.all(ids.map((id) => from.records.entry(id))))
}

export const states = async (harness: Harness): Promise<ReadonlyArray<Partial<Sandbox>>> =>
  (await harness.machines.list()).map(({ id, state }) => ({ id, state }))

const machineFor = async (
  self: Member,
  fleet: Pick<Fleet, "holder" | "hostLocal">,
  servers: Map<string, { server: RunningCodevisorServer; tickets: FleetTickets }>,
  options: SandboxHarnessOptions
): Promise<Machine> => {
  const harness = await sandboxHarness({
    ...options,
    serverId: self.serverId,
    management: makeSandboxManagement({
      roles: {
        holding: () => (fleet.holder === self.deviceId ? heldRole : undefined),
        views: () => [
          {
            role: SANDBOX_MANAGER_ROLE,
            version: 1,
            held: fleet.holder === self.deviceId,
            ...(fleet.holder === undefined ? {} : { holder: fleet.holder })
          }
        ],
        run: () => () => undefined
      },
      cloud: { deviceId: () => self.deviceId, machines: () => harness.presences },
      link: {
        invoke: async (machineId, path, args, origin) => {
          const target = servers.get(machineId)
          if (target === undefined) throw new Error(`No machine ${machineId}`)
          return answerOf(
            await withTicket(
              target.tickets.callers,
              { deviceId: self.deviceId, publicKey: "pk" },
              (ticket) => post(target.server.url, { path, args, origin }, ticket)
            )
          )
        }
      },
      serverId: self.serverId,
      machineName: () => self.serverId,
      hostLocal: () => fleet.hostLocal
    })
  })
  const tickets = makeFleetTickets()
  const server = await startWithApp({
    ...harness.services,
    fleetTickets: tickets,
    machines: {
      list: () => Promise.resolve([]),
      resolve: () => undefined,
      invoke: () => Promise.reject(new Error("unused")),
      machineIdOf: (caller) =>
        [laptop, studio].find((m) => m.deviceId === caller.deviceId)?.serverId
    },
    sandboxes: { sandboxes: harness.machines, catalog: harness.catalog }
  })
  servers.set(self.serverId, { server, tickets })
  return { harness, server }
}

const heldRole: HeldRole = {
  role: SANDBOX_MANAGER_ROLE,
  version: 1,
  signal: new AbortController().signal,
  fence: { role: SANDBOX_MANAGER_ROLE, version: 1 },
  held: () => true
}

interface Answer {
  readonly status: number
  readonly body: unknown
}

const post = async (url: string, body: unknown, ticket: string): Promise<Answer> => {
  const response = await fetch(`${url}/v1/gateway/invoke`, {
    method: "POST",
    headers: { "content-type": "application/json", [FLEET_CALLER_HEADER]: ticket },
    body: JSON.stringify(body)
  })
  return { status: response.status, body: (await response.json()) as unknown }
}

const answerOf = ({ status, body }: Answer): unknown => {
  if (status === 200 && isRecord(body)) return body.result
  const error = isRecord(body) && isRecord(body.error) ? String(body.error.message) : ""
  throw new PeerAnswerError(error, {}, status)
}
