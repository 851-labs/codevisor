import type { CodevisorDatabaseService, FleetMessage } from "@codevisor/db"

import { run } from "../server-context.js"
import { makeKeyedDrains } from "./keyed-drains.js"
import { PeerAnswerError, type MachineLink } from "./machine-link.js"

export interface FleetOutbox {
  readonly flush: () => Promise<void>
  readonly expire: () => Promise<void>
}

export interface FleetOutboxOptions {
  readonly db: CodevisorDatabaseService
  readonly machines: MachineLink
  readonly now: () => number
  readonly attemptSignal?: () => AbortSignal
}

export interface FleetLink {
  readonly machines: MachineLink
  readonly outbox: FleetOutbox
}

export const FLEET_MESSAGE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1_000
export const FLEET_DELIVERY_MEMORY_MS = 30 * 24 * 60 * 60 * 1_000
export const FLEET_OUTBOX_RETRY_MS = 30_000
export const FLEET_ATTEMPT_TIMEOUT_MS = 60_000

export const makeFleetOutbox = (options: FleetOutboxOptions): FleetOutbox => {
  const destinations = makeKeyedDrains((machineId) => drainDestination(options, machineId))
  const expire = (): Promise<void> => run(options.db.expireFleetBefore(expiryCutoff(options)))
  return {
    flush: async () => {
      await expire()
      const queued = await run(options.db.listFleetMessages)
      const machineIds = new Set(queued.map((message) => message.machineId))
      await Promise.all([...machineIds].map(destinations.drain))
    },
    expire
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

const drainDestination = async (options: FleetOutboxOptions, machineId: string) => {
  for (;;) {
    const message = await run(options.db.nextFleetMessageFor(machineId, expiryCutoff(options)))
    if (message === undefined || !(await settled(options, message))) return
    await run(options.db.deleteFleetMessage(message.id))
  }
}

const settled = async (options: FleetOutboxOptions, message: FleetMessage): Promise<boolean> => {
  try {
    const { machineId, path, args, origin } = message
    await options.machines.invoke(machineId, path, args, origin, attemptSignal(options))
    return true
  } catch (cause) {
    return refusedForGood(cause)
  }
}

const RETRYABLE_REFUSALS = new Set([408, 425, 429])

const refusedForGood = (cause: unknown): boolean =>
  cause instanceof PeerAnswerError &&
  cause.status >= 400 &&
  cause.status < 500 &&
  !RETRYABLE_REFUSALS.has(cause.status)

const attemptSignal = (options: FleetOutboxOptions): AbortSignal =>
  options.attemptSignal?.() ?? AbortSignal.timeout(FLEET_ATTEMPT_TIMEOUT_MS)

const expiryCutoff = (options: FleetOutboxOptions): string =>
  new Date(options.now() - FLEET_MESSAGE_MAX_AGE_MS).toISOString()
