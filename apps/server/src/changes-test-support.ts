import { EventEmitter } from "node:events"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

// Test fixtures publish actual state changes; waiters never poll the clock.
const changes = new EventEmitter()
export const fixtureChanged = (): void => {
  changes.emit("change")
}

export const observableFixture = <T extends object>(value: T): T =>
  new Proxy(value, {
    set(target, key, value) {
      const changed = Reflect.set(target, key, value)
      fixtureChanged()
      return changed
    }
  })

export const observeDatabase = (db: CodevisorDatabaseService): void => {
  for (const [name, operation] of Object.entries(db)) {
    if (
      typeof operation !== "function" ||
      !/^(append|apply|archive|claim|clear|create|delete|enqueue|import|mark|promote|prune|record|remove|replace|save|set|settle|update|upsert)/.test(
        name
      )
    )
      continue
    const mutate = operation as (...args: unknown[]) => Effect.Effect<unknown, unknown>
    Object.assign(db, {
      [name]: (...args: unknown[]) => Effect.tap(mutate(...args), () => Effect.sync(fixtureChanged))
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
