import { MachineCallOrigin } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { parseJsonColumn, parseJsonObject } from "./json-column.js"
import { insertPromptQueueItem } from "./prompt-queue-service.js"
import { rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface FleetMessage {
  readonly id: string
  readonly machineId: string
  readonly path: string
  readonly args: Readonly<Record<string, unknown>>
  readonly origin: MachineCallOrigin
  readonly createdAt: string
}

export interface FleetPrompt {
  readonly deliveryId: string
  readonly receivedAt: string
  readonly sessionId: string
  readonly text: string
}

export interface FleetOutboxService {
  readonly listFleetMessages: Effect.Effect<ReadonlyArray<FleetMessage>, DatabaseError>
  readonly nextFleetMessageFor: (
    machineId: string,
    notBefore: string
  ) => Effect.Effect<FleetMessage | undefined, DatabaseError>
  readonly deleteFleetMessage: (id: string) => Effect.Effect<void, DatabaseError>
  readonly expireFleetBefore: (createdAt: string) => Effect.Effect<void, DatabaseError>
  readonly acceptFleetPrompt: (prompt: FleetPrompt) => Effect.Effect<boolean, DatabaseError>
  readonly enqueueFleetMessage: (message: FleetMessage) => Effect.Effect<void, DatabaseError>
  readonly pruneFleetDeliveries: (before: string) => Effect.Effect<void, DatabaseError>
}

export const makeFleetOutboxService = (context: ServiceContext): FleetOutboxService => {
  const { sqlite } = context

  return {
    listFleetMessages: attempt("listFleetMessages", () =>
      fleetMessageRows.all(sqlite.prepare(fleetSql.list).all()).map(messageFromRow)
    ),
    nextFleetMessageFor: (machineId, notBefore) =>
      attempt("nextFleetMessageFor", () => {
        const row = fleetMessageRows.maybe(
          sqlite.prepare(fleetSql.nextFor).get(machineId, notBefore)
        )
        return row === undefined ? undefined : messageFromRow(row)
      }),
    expireFleetBefore: (createdAt) =>
      attempt("expireFleetBefore", () => {
        sqlite.prepare(fleetSql.deleteBefore).run(createdAt)
      }),
    deleteFleetMessage: (id) =>
      attempt("deleteFleetMessage", () => {
        sqlite.prepare(fleetSql.delete).run(id)
      }),
    acceptFleetPrompt: (prompt) => attempt("acceptFleetPrompt", () => acceptOnce(context, prompt)),
    enqueueFleetMessage: (message) =>
      attempt("enqueueFleetMessage", () => {
        sqlite.prepare(fleetSql.enqueue).run(...messageValues(message))
      }),
    pruneFleetDeliveries: (before) =>
      attempt("pruneFleetDeliveries", () => {
        sqlite.prepare(fleetSql.pruneDeliveries).run(before)
      })
  }
}

const acceptOnce = (context: ServiceContext, prompt: FleetPrompt): boolean =>
  context.sqlite.transaction(() => {
    const receipt = context.sqlite
      .prepare(fleetSql.recordDelivery)
      .run(prompt.deliveryId, prompt.receivedAt)
    if (receipt.changes === 0) return false
    insertPromptQueueItem(context, {
      rawSessionId: prompt.sessionId,
      text: prompt.text,
      origin: "system"
    })
    return true
  })()

const messageValues = (message: FleetMessage) =>
  [
    message.id,
    message.machineId,
    message.path,
    JSON.stringify(message.args),
    JSON.stringify(message.origin),
    message.createdAt
  ] as const

const messageFromRow = (row: FleetMessageRow): FleetMessage => ({
  id: row.id,
  machineId: row.machine_id,
  path: row.path,
  args: parseJsonObject(row.args),
  origin: parseJsonColumn(MachineCallOrigin, row.origin),
  createdAt: row.created_at
})

interface FleetMessageRow {
  readonly id: string
  readonly machine_id: string
  readonly path: string
  readonly args: string
  readonly origin: string
  readonly created_at: string
}

const fleetMessageRows = rowReader<FleetMessageRow>({
  id: text,
  machine_id: text,
  path: text,
  args: text,
  origin: text,
  created_at: text
})

const fleetSql = {
  enqueue: `insert into fleet_outbox (id, machine_id, path, args, origin, created_at)
            values (?, ?, ?, ?, ?, ?)
            on conflict(id) do nothing`,
  list: "select * from fleet_outbox order by rowid",
  nextFor: `select * from fleet_outbox where machine_id = ? and created_at >= ?
            order by rowid limit 1`,
  deleteBefore: "delete from fleet_outbox where created_at < ?",
  delete: "delete from fleet_outbox where id = ?",
  recordDelivery: `insert into fleet_deliveries (delivery_id, received_at) values (?, ?)
                   on conflict(delivery_id) do nothing`,
  pruneDeliveries: "delete from fleet_deliveries where received_at < ?"
}
