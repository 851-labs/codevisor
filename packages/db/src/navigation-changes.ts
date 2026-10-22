import { isoTimestamp, type EventEnvelope } from "@codevisor/api"

import { cursorRows } from "./common-rows.js"
import { eventFromRow } from "./row-mappers.js"
import { eventRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"

export const journaledNavigationChanges =
  ({ sqlite }: ServiceContext) =>
  (update: (now: string) => void): ReadonlyArray<EventEnvelope> =>
    sqlite.transaction(() => {
      const cursor = latestEventId(sqlite)
      update(isoTimestamp())
      return navigationEventsAfter(sqlite, cursor).map(eventFromRow)
    })()

const latestEventId = (sqlite: ServiceContext["sqlite"]): number =>
  cursorRows.one(sqlite.prepare(navigationChangeSql.latestEventId).get()).cursor

const navigationEventsAfter = (sqlite: ServiceContext["sqlite"], cursor: number) =>
  eventRows.all(sqlite.prepare(navigationChangeSql.eventsAfter).all(cursor))

const navigationChangeSql = {
  latestEventId: "select coalesce(max(id), 0) as cursor from events",
  eventsAfter: "select * from events where id > ? and kind = 'navigation.changed' order by id"
}
