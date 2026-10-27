import type { CloudEnv } from "./env.js"
import { pluginPageUrl, pluginPublisher } from "./plugin-ids.js"

export const notifyPluginReports = async (env: CloudEnv): Promise<void> => {
  const webhook = reportWebhook(env)
  if (webhook === undefined) return

  const pending = await pendingReports(env.DB)
  for (const report of pending) await deliverReport(env, webhook, report)
}

interface PendingReport {
  id: string
  plugin_id: string
  plugin_name: string
  reason: string
  details: string
}

const slackTimeoutMs = 5000
const pendingBatchSize = 20

const reportWebhook = (env: CloudEnv): URL | undefined => {
  if (!env.PLUGIN_REPORT_SLACK_WEBHOOK) return undefined

  const url = new URL(env.PLUGIN_REPORT_SLACK_WEBHOOK)
  if (!isSlackWebhook(url)) throw new Error("Invalid plugin report webhook configuration")
  return url
}

const isSlackWebhook = (url: URL): boolean =>
  url.origin === "https://hooks.slack.com" && url.pathname.startsWith("/services/")

const deliverReport = async (env: CloudEnv, webhook: URL, report: PendingReport) => {
  const delivered = await postToSlack(env, webhook, report).catch(() => false)
  if (!delivered) return

  await env.DB.prepare(reportSql.markNotified).bind(Date.now(), report.id).run()
}

const postToSlack = async (env: CloudEnv, webhook: URL, report: PendingReport) => {
  const response = await (env.PLUGIN_REPORT_FETCH ?? fetch)(webhook.toString(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    signal: AbortSignal.timeout(slackTimeoutMs),
    body: JSON.stringify({
      blocks: [{ type: "section", text: { type: "plain_text", text: reportText(report) } }]
    })
  })
  return response.ok
}

const reportText = (report: PendingReport): string =>
  [
    `Plugin report: ${report.plugin_name}`,
    `Plugin: ${report.plugin_id}`,
    `Publisher: ${pluginPublisher(report.plugin_id)}`,
    `Page: ${pluginPageUrl(report.plugin_id)}`,
    `Reason: ${report.reason}`,
    report.details,
    `Report: ${report.id}`
  ].join("\n")

const pendingReports = async (db: D1Database): Promise<PendingReport[]> =>
  (await db.prepare(reportSql.pending).bind(pendingBatchSize).all<PendingReport>()).results

const reportSql = {
  pending:
    "SELECT id, plugin_id, plugin_name, reason, details FROM plugin_reports WHERE notified_at IS NULL ORDER BY created_at LIMIT ?",
  markNotified: "UPDATE plugin_reports SET notified_at = ? WHERE id = ?"
}
