import type { CloudEnv } from "./env.js"

interface PendingReport {
  id: string
  plugin_id: string
  plugin_name: string
  reason: string
  details: string
}

/** Durable outbox: reports survive webhook failures and retry on the next cron. */
export const notifyPluginReports = async (env: CloudEnv): Promise<void> => {
  if (!env.PLUGIN_REPORT_SLACK_WEBHOOK) return
  const url = new URL(env.PLUGIN_REPORT_SLACK_WEBHOOK)
  if (url.origin !== "https://hooks.slack.com" || !url.pathname.startsWith("/services/")) {
    throw new Error("Invalid plugin report webhook configuration")
  }
  const pending = await env.DB.prepare(
    "SELECT id, plugin_id, plugin_name, reason, details FROM plugin_reports WHERE notified_at IS NULL ORDER BY created_at LIMIT 20"
  ).all<PendingReport>()
  for (const report of pending.results) {
    try {
      const response = await (env.PLUGIN_REPORT_FETCH ?? fetch)(url.toString(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal: AbortSignal.timeout(5000),
        body: JSON.stringify({
          // Plain text blocks keep user input from creating mentions or links.
          blocks: [
            {
              type: "section",
              text: {
                type: "plain_text",
                text: `Plugin report: ${report.plugin_name}\nPlugin: ${report.plugin_id}\nReason: ${report.reason}\n${report.details}\nReport: ${report.id}`
              }
            }
          ]
        })
      })
      if (!response.ok) continue
      await env.DB.prepare("UPDATE plugin_reports SET notified_at = ? WHERE id = ?")
        .bind(Date.now(), report.id)
        .run()
    } catch {
      // Leave the report pending. Never log the webhook or report contents.
    }
  }
}
