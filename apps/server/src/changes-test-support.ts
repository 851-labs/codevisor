import { EventEmitter } from "node:events"

import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

const changes = new EventEmitter()
export const fixtureChanged = (): void => {
  changes.emit("change")
}

export const observableFixture = <T extends object>(value: T): T =>
  new Proxy(value, {
    set(target, key, assigned) {
      const changed = Reflect.set(target, key, assigned)
      fixtureChanged()
      return changed
    }
  })

export const observeDatabase = (db: CodevisorDatabaseService): void => {
  for (const [name, operation] of Object.entries(db)) {
    if (
      typeof operation !== "function" ||
      !/^(append|apply|archive|claim|clear|create|delete|enqueue|import|mark|merge|promote|prune|record|remove|replace|save|set|settle|update|upsert)/.test(
        name
      )
    )
      continue
    Object.assign(db, {
      [name]: (...args: unknown[]) => {
        const result: unknown = Reflect.apply(operation, db, args)
        return Effect.isEffect(result)
          ? Effect.tap(result, () => Effect.sync(fixtureChanged))
          : result
      }
    })
  }
}

export const waitFor = async (
  predicate: () => boolean | Promise<boolean>,
  _describeState?: () => string
): Promise<void> => {
  while (true) {
    const next = Promise.withResolvers<void>()
    const listener = () => next.resolve()
    changes.once("change", listener)
    try {
      if (await predicate()) return
      await next.promise
    } finally {
      changes.off("change", listener)
    }
  }
}
