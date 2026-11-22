import { describe, expect, it } from "vitest"

import { routeTag } from "./route-tag.js"

const request = (method: string, url: string) => ({ method, url })

describe("routeTag", () => {
  it("keeps route words and hides identifiers, names, and queries", () => {
    expect(
      routeTag(request("POST", "/v1/sessions/0F8E2C4A-1111-2222-3333-444455556666/prompt?x=secret"))
    ).toBe("POST /v1/sessions/:id/prompt")
    expect(routeTag(request("GET", "/v1/projects/My-App/files/extra/deeper"))).toBe(
      "GET /v1/projects/:id/files/extra"
    )
    expect(routeTag(undefined)).toBe("? /")
  })
})
