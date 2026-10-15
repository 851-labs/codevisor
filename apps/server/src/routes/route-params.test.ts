import { describe, expect, it } from "vitest"

import { routeParam } from "./route-params.js"

describe("routeParam", () => {
  it("returns captured parameters and rejects missing ones", () => {
    expect(routeParam({ id: "session-1" }, "id")).toBe("session-1")
    expect(() => routeParam({ id: "session-1" }, "queueId")).toThrow(
      "Route parameter queueId is missing"
    )
  })
})
