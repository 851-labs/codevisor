import { describe, expect, it } from "vitest"

import type { HarnessFailure } from "./harness-failure-stops.js"
import { harnessFailureKind, harnessFailureStop } from "./harness-failure-stops.js"

const orgDisabled =
  "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"

describe("harness failure stops", () => {
  it.each<[string, HarnessFailure, ReturnType<typeof harnessFailureKind>]>([
    ["a 401 status", { message: "Request failed", status: 401 }, "authRequired"],
    [
      "a sign-in error code",
      { message: "Not logged in", code: "authentication_failed" },
      "authRequired"
    ],
    ["a 403 status", { message: "Request failed", status: 403 }, "forbidden"],
    [
      "Claude's org access code",
      { message: orgDisabled, code: "oauth_org_not_allowed" },
      "forbidden"
    ],
    ["Claude's org access text alone", { message: orgDisabled }, "forbidden"],
    ["an API permission error", { message: "permission_error: Request not allowed" }, "forbidden"],
    ["a region block", { message: "This service is not available in your region." }, "forbidden"],
    [
      "an OpenAI region code",
      {
        message: "Country, region, or territory not supported",
        code: "unsupported_country_region_territory"
      },
      "forbidden"
    ],
    ["an HTTP 403 in the text", { message: "API Error: 403 Forbidden" }, "forbidden"],
    ["a crash", { message: "ACP connection closed" }, "harnessFailed"],
    [
      "a server error",
      { message: "API Error: 500 Internal Server Error", status: 500 },
      "harnessFailed"
    ],
    ["an unknown error code", { message: "Something broke", code: "unknown" }, "harnessFailed"],
    ["a tool the agent may not run", { message: "Tool not allowed: Bash" }, "harnessFailed"],
    [
      "a port number containing 403",
      { message: "connect ECONNREFUSED 127.0.0.1:4030" },
      "harnessFailed"
    ]
  ])("classifies %s", (_, failure, kind) => {
    expect(harnessFailureKind(failure)).toBe(kind)
  })

  it("keeps the harness's own message as the stop detail", () => {
    expect(harnessFailureStop({ message: orgDisabled, status: 403 })).toEqual({
      stopKind: "forbidden",
      stopDetail: orgDisabled
    })
  })
})
