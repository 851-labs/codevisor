import { MachineCallOrigin } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { parseJsonColumn, parseJsonObject } from "./json-column.js"
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

export interface FleetOutboxService {
  readonly enqueueFleetMessage: (message: FleetMessage) => Effect.Effect<void, DatabaseError>
  readonly listFleetMessages: Effect.Effect<ReadonlyArray<FleetMessage>, DatabaseError>
  readonly deleteFleetMessage: (id: string) => Effect.Effect<void, DatabaseError>
  readonly recordFleetDelivery: (
    deliveryId: string,
    receivedAt: string
  ) => Effect.Effect<boolean, DatabaseError>
  readonly pruneFleetDeliveries: (before: string) => Effect.Effect<void, DatabaseError>
}

export const makeFleetOutboxService = (context: ServiceContext): FleetOutboxService => {
  const { sqlite } = context

  return {
    enqueueFleetMessage: (message) =>
      attempt("enqueueFleetMessage", () => {
        sqlite.prepare(fleetSql.enqueue).run(...messageValues(message))
      }),
    listFleetMessages: attempt("listFleetMessages", () =>
      fleetMessageRows.all(sqlite.prepare(fleetSql.list).all()).map(messageFromRow)
    ),
    deleteFleetMessage: (id) =>
      attempt("deleteFleetMessage", () => {
        sqlite.prepare(fleetSql.delete).run(id)
      }),
    recordFleetDelivery: (deliveryId, receivedAt) =>
      attempt(
        "recordFleetDelivery",
        () => sqlite.prepare(fleetSql.recordDelivery).run(deliveryId, receivedAt).changes > 0
      ),
    pruneFleetDeliveries: (before) =>
      attempt("pruneFleetDeliveries", () => {
        sqlite.prepare(fleetSql.pruneDeliveries).run(before)
      })
  }
}

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
            values (?, ?, ?, ?, ?, ?)`,
  list: "select * from fleet_outbox order by rowid",
  delete: "delete from fleet_outbox where id = ?",
  recordDelivery: `insert into fleet_deliveries (delivery_id, received_at) values (?, ?)
                   on conflict(delivery_id) do nothing`,
  pruneDeliveries: "delete from fleet_deliveries where received_at < ?"
}
