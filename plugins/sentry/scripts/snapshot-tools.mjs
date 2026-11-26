import { writeFileSync } from "node:fs"

import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client"

const token = process.env.SENTRY_ACCESS_TOKEN
if (token === undefined || token === "") {
  console.error("Set SENTRY_ACCESS_TOKEN to a Sentry user auth token or OAuth token.")
  process.exit(1)
}

const skipped = new Set([
  "add_team_to_project",
  "create_alert_rule",
  "create_metric_monitor",
  "create_monitor",
  "create_team",
  "create_uptime_monitor",
  "delete_alert_rule",
  "delete_metric_monitor",
  "delete_monitor_environment",
  "delete_uptime_monitor",
  "get_ai_conversation_details",
  "get_alert_options",
  "get_sentry_mcp_info",
  "onboarding_status_update",
  "remove_team_from_project",
  "search_ai_conversations",
  "search_events",
  "submit_feedback_to_sentry_team",
  "update_alert_rule",
  "update_dsn",
  "update_metric_monitor",
  "update_project",
  "update_uptime_monitor"
])

const client = new Client({ name: "codevisor-sentry-snapshot", version: "1.0.0" })
await client.connect(
  new StreamableHTTPClientTransport(new URL("https://mcp.sentry.dev/mcp"), {
    requestInit: { headers: { Authorization: `Sentry-Bearer ${token}` } }
  })
)
const { tools } = await client.listTools()
await client.close()

const snapshot = tools
  .filter((tool) => !skipped.has(tool.name))
  .map(({ name, title, description, inputSchema, annotations }) => ({
    name,
    title,
    description,
    inputSchema,
    annotations
  }))
writeFileSync(
  new URL("../src/sentry-mcp-tools.json", import.meta.url),
  `${JSON.stringify(snapshot, null, 2)}\n`
)
console.log(`Saved ${snapshot.length} Sentry MCP tools. Update server.json's tool digest to match.`)
