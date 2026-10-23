import { randomUUID } from "node:crypto"

import type { MachineCallOrigin } from "@codevisor/api"
import type { CodevisorDatabaseService, FleetMessage } from "@codevisor/db"

import { run } from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import type { MachineLink } from "./machine-link.js"

export interface FleetOutbox {
  readonly send: (
    machineId: string,
    path: string,
    args: unknown,
    origin: MachineCallOrigin
  ) => Promise<void>
  readonly flush: () => Promise<void>
}

export interface FleetOutboxOptions {
  readonly db: CodevisorDatabaseService
  readonly machines: MachineLink
  readonly now: () => number
}

export interface FleetLink {
  readonly machines: MachineLink
  readonly outbox: FleetOutbox
}

export const FLEET_MESSAGE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1_000
export const FLEET_DELIVERY_MEMORY_MS = 30 * 24 * 60 * 60 * 1_000
export const FLEET_OUTBOX_RETRY_MS = 30_000

export const makeFleetOutbox = (options: FleetOutboxOptions): FleetOutbox => {
  let chain = Promise.resolve()
  const flush = (): Promise<void> => {
    chain = chain.catch(() => undefined).then(() => drain(options))
    return chain
  }
  return {
    send: async (machineId, path, args, origin) => {
      await run(options.db.enqueueFleetMessage(newMessage(options, machineId, path, args, origin)))
      await flush()
    },
    flush
  }
}

export const fleetLinkFor = (services: {
  readonly db: CodevisorDatabaseService
  readonly machines?: MachineLink | undefined
}): FleetLink | undefined => {
  const machines = services.machines
  if (machines === undefined) return undefined
  return { machines, outbox: makeFleetOutbox({ db: services.db, machines, now: Date.now }) }
}

export const forgetOldFleetDeliveries = (
  services: { readonly db: CodevisorDatabaseService },
  now: number = Date.now()
): Promise<void> =>
  run(services.db.pruneFleetDeliveries(new Date(now - FLEET_DELIVERY_MEMORY_MS).toISOString()))

const newMessage = (
  options: FleetOutboxOptions,
  machineId: string,
  path: string,
  args: unknown,
  origin: MachineCallOrigin
): FleetMessage => {
  const id = randomUUID()
  return {
    id,
    machineId,
    path,
    args: { ...(isRecord(args) ? args : {}), deliveryId: id },
    origin,
    createdAt: new Date(options.now()).toISOString()
  }
}

const drain = async (options: FleetOutboxOptions): Promise<void> => {
  const offline = new Set<string>()
  for (const message of await run(options.db.listFleetMessages)) {
    if (offline.has(message.machineId)) continue
    const outcome = await deliver(options, message)
    if (outcome === "offline") offline.add(message.machineId)
    else await run(options.db.deleteFleetMessage(message.id))
  }
}

type DeliveryOutcome = "delivered" | "refused" | "expired" | "offline"

const deliver = async (
  options: FleetOutboxOptions,
  message: FleetMessage
): Promise<DeliveryOutcome> => {
  if (expired(options, message)) return "expired"
  try {
    await options.machines.invoke(message.machineId, message.path, message.args, message.origin)
    return "delivered"
  } catch (cause) {
    return isUnavailable(cause) ? "offline" : "refused"
  }
}

const expired = (options: FleetOutboxOptions, message: FleetMessage): boolean =>
  options.now() - Date.parse(message.createdAt) > FLEET_MESSAGE_MAX_AGE_MS

const isUnavailable = (cause: unknown): boolean =>
  isRecord(cause) && cause.code === "machine_unavailable"
