import { describe, expect, it } from "vitest"

import { definition, run, setup } from "./test-support.js"

describe("Pi forks", () => {
  it("starts a fork by launching Pi with --fork on the source session", async () => {
    const { provider, spawned } = setup()

    await run(
      provider.createSession(definition, "/project", async () => undefined, undefined, undefined, {
        forkFrom: "pi-source"
      })
    )

    expect(spawned[0]?.args).toEqual(["--approve", "--fork", "pi-source"])
  })
})
