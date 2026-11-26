import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import { missingSentryAccount, rejectedSentrySignIn } from "./sentry-account.js"
import { accountFor, connectSentry } from "./sentry-test-support.js"

describe("sentry tools", () => {
  it("serves Sentry's own MCP tools with their hints, without the admin and deprecated ones", async () => {
    const { client } = await connectSentry()

    const { tools } = await client.listTools()
    const names = tools.map((tool) => tool.name)

    expect(tools).toHaveLength(56)
    expect(tools.find((tool) => tool.name === "update_issue")?.annotations).toMatchObject({
      readOnlyHint: false,
      destructiveHint: true
    })
    expect(tools.find((tool) => tool.name === "search_issues")?.annotations?.readOnlyHint).toBe(
      true
    )
    expect(names).toEqual(expect.arrayContaining(["get_issue_details", "find_releases"]))
    for (const skipped of [
      "delete_alert_rule",
      "create_team",
      "search_events",
      "get_alert_options"
    ])
      expect(names).not.toContain(skipped)
  })

  it("runs a call on Sentry's MCP server with the account's own token", async () => {
    const { client, sentry } = await connectSentry()

    const result = await client.callTool({
      name: "search_issues",
      arguments: { organizationSlug: "acme", query: "is:unresolved assigned:me" },
      _meta: accountFor()
    })

    expect(toolText(result)).toBe("ran search_issues")
    expect(result.structuredContent).toEqual({ ok: true })
    expect(sentry.mcpCalls).toEqual([
      {
        name: "search_issues",
        arguments: { organizationSlug: "acme", query: "is:unresolved assigned:me" }
      }
    ])
  })

  it("asks for a sign-in when the account is missing or Sentry rejects its token", async () => {
    const { client, sentry } = await connectSentry()

    const missing = await client.callTool({ name: "search_issues", arguments: {} })
    const rejected = await client.callTool({
      name: "search_issues",
      arguments: {},
      _meta: accountFor("sntryu_revoked")
    })

    expect([missing.isError, toolText(missing)]).toEqual([true, missingSentryAccount])
    expect([rejected.isError, toolText(rejected)]).toEqual([true, rejectedSentrySignIn])
    expect(sentry.mcpCalls).toEqual([])
  })

  it("refuses tools it doesn't offer, including Sentry's admin tools", async () => {
    const { client, sentry } = await connectSentry()

    const result = await client.callTool({
      name: "delete_alert_rule",
      arguments: {},
      _meta: accountFor()
    })

    expect([result.isError, toolText(result)]).toEqual([true, "Unknown tool: delete_alert_rule"])
    expect(sentry.mcpCalls).toEqual([])
  })
})
