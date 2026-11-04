import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import { missingLinearAccount, rejectedLinearSignIn } from "./linear-account.js"
import { accountFor, connectLinear } from "./linear-test-support.js"

describe("linear tools", () => {
  it("serves Linear's own MCP tools with their schemas and hints", async () => {
    const { client } = await connectLinear()

    const { tools } = await client.listTools()

    expect(tools.find((tool) => tool.name === "save_comment")).toMatchObject({
      inputSchema: { required: ["body"] },
      annotations: { readOnlyHint: false }
    })
    expect(tools.find((tool) => tool.name === "list_issues")?.annotations?.readOnlyHint).toBe(true)
  })

  it("runs a call on Linear's MCP server as the signed-in account", async () => {
    const { client, linear } = await connectLinear()

    const result = await client.callTool({
      name: "list_issues",
      arguments: { assignee: "me", team: "ENG" },
      _meta: accountFor()
    })

    expect(toolText(result)).toBe("ran list_issues")
    expect(result.structuredContent).toEqual({ ok: true })
    expect(linear.mcpCalls).toEqual([
      { name: "list_issues", arguments: { assignee: "me", team: "ENG" } }
    ])
  })

  it("asks for a sign-in when the account is missing or Linear rejects its token", async () => {
    const { client, linear } = await connectLinear()

    const missing = await client.callTool({ name: "list_issues", arguments: {} })
    const rejected = await client.callTool({
      name: "list_issues",
      arguments: {},
      _meta: accountFor("lin_oauth_revoked")
    })

    expect([missing.isError, toolText(missing)]).toEqual([true, missingLinearAccount])
    expect([rejected.isError, toolText(rejected)]).toEqual([true, rejectedLinearSignIn])
    expect(linear.mcpCalls).toEqual([])
  })

  it("refuses tools Linear's MCP server doesn't offer", async () => {
    const { client, linear } = await connectLinear()

    const result = await client.callTool({
      name: "drop_workspace",
      arguments: {},
      _meta: accountFor()
    })

    expect([result.isError, toolText(result)]).toEqual([true, "Unknown tool: drop_workspace"])
    expect(linear.mcpCalls).toEqual([])
  })
})
