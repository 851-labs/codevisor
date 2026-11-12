import { describe, expect, it } from "vitest"

import { isTransientGitHubError } from "./github-errors.ts"
import { parseShipArguments } from "./ship-arguments.ts"

describe("parseShipArguments", () => {
  it("collects flags and pull request details", () => {
    expect(parseShipArguments(["--review", "--title", "Fix it", "--body-file", "body.md"])).toEqual(
      {
        review: true,
        pullRequestDetails: ["--title", "Fix it", "--body-file", "body.md"]
      }
    )
  })

  it("rejects unknown arguments and details without a value", () => {
    expect(() => parseShipArguments(["--bogus"])).toThrow(/unknown argument --bogus/)
    expect(() => parseShipArguments(["--title"])).toThrow(/unknown argument --title/)
  })
})

describe("isTransientGitHubError", () => {
  it("retries GitHub outages but not request errors", () => {
    expect(isTransientGitHubError("GraphQL: Something went wrong while executing your query")).toBe(
      true
    )
    expect(isTransientGitHubError("error connecting to api.github.com")).toBe(true)
    expect(isTransientGitHubError("HTTP 422: Validation Failed")).toBe(false)
  })
})
