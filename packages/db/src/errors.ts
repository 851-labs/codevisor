import { Effect, Schema } from "effect"

export class DatabaseError extends Schema.TaggedErrorClass<DatabaseError>()("DatabaseError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export const attempt = <A>(operation: string, run: () => A): Effect.Effect<A, DatabaseError> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      new DatabaseError({
        operation,
        /* v8 ignore next */
        message: cause instanceof Error ? cause.message : String(cause)
      })
  })
