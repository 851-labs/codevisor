import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { CodevisorDatabase } from "./index.js"
import { tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("constructs the Effect service layer", async () => {
    const info = await Effect.runPromise(
      Effect.gen(function* () {
        const db = yield* CodevisorDatabase
        const update = yield* db.getUpdateInfo
        yield* db.close
        return update
      }).pipe(
        Effect.provide(
          CodevisorDatabase.layer({
            filename: tempDatabase(),
            serverId: "layered"
          })
        )
      )
    )

    expect(info.currentVersion).toBe("0.1.0")
  })
})
