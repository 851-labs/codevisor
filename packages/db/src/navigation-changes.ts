import { isoTimestamp, type EventEnvelope } from "@codevisor/api"

import { cursorRows } from "./common-rows.js"
import { eventFromRow } from "./row-mappers.js"
import { eventRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"

export const journaledNavigationChanges =
  ({ sqlite }: ServiceContext) =>
  (update: (now: string) => void): ReadonlyArray<EventEnvelope> =>
    sqlite.transaction(() => {
      const { cursor } = cursorRows.one(
        sqlite.prepare("select coalesce(max(id), 0) as cursor from events").get()
      )
      update(isoTimestamp())
      return eventRows
        .all(
          sqlite
            .prepare(
              "select * from events where id > ? and kind = 'navigation.changed' order by id"
            )
            .all(cursor)
        )
        .map(eventFromRow)
    })()
