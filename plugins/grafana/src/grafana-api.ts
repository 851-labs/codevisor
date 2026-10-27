import { errorResult, jsonResult } from "@codevisor/plugin-kit"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import type { GrafanaAccount } from "./grafana-account.js"

export type Fetch = typeof fetch

export const runGrafanaTool = async (
  name: string,
  args: Record<string, unknown>,
  account: GrafanaAccount,
  fetcher: Fetch
): Promise<CallToolResult> => {
  const call = grafanaCall(name, args)
  if ("error" in call) return errorResult(call.error)

  return fetchJson(fetcher, account, call.request)
}

interface GrafanaRequest {
  path: string
  method: "GET" | "POST"
  body?: unknown
}

type GrafanaCall = { request: GrafanaRequest } | { error: string }

const grafanaCall = (name: string, args: Record<string, unknown>): GrafanaCall => {
  const builder = requestBuilders[name]
  if (builder === undefined) return failed(`Unknown tool: ${name}`)

  return builder(args)
}

const requestBuilders: Record<string, (args: Record<string, unknown>) => GrafanaCall> = {
  list_alerts: () => ({
    request: { path: "/api/prometheus/grafana/api/v1/alerts", method: "GET" }
  }),
  get_alert_rule: (args) => {
    const parsed = alertRuleArguments.safeParse(args)
    if (!parsed.success) return failed(z.prettifyError(parsed.error))

    return {
      request: {
        path: `/api/v1/provisioning/alert-rules/${encodeURIComponent(parsed.data.uid)}`,
        method: "GET"
      }
    }
  },
  query: (args) => {
    const parsed = queryArguments.safeParse(args)
    if (!parsed.success) return failed(z.prettifyError(parsed.error))

    return { request: { path: "/api/ds/query", method: "POST", body: queryBody(parsed.data) } }
  }
}

const failed = (error: string): GrafanaCall => ({ error })

const queryBody = (args: z.infer<typeof queryArguments>) => ({
  from: args.from,
  to: args.to,
  queries: [{ refId: "A", ...args.query, datasource: { uid: args.datasourceUid } }]
})

const fetchJson = async (
  fetcher: Fetch,
  account: GrafanaAccount,
  request: GrafanaRequest
): Promise<CallToolResult> => {
  try {
    const response = await fetcher(`${account.url}${request.path}`, requestInit(account, request))
    const text = await response.text()
    if (!response.ok) return errorResult(`Grafana returned ${response.status}: ${text}`)

    return jsonResult(parsedBody(text))
  } catch (error) {
    return errorResult(`Grafana request failed: ${String(error)}`)
  }
}

const requestInit = (account: GrafanaAccount, request: GrafanaRequest): RequestInit => ({
  method: request.method,
  headers: {
    Authorization: `Bearer ${account.token}`,
    Accept: "application/json",
    "Content-Type": "application/json"
  },
  ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) })
})

const parsedBody = (text: string): unknown => {
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

const alertRuleArguments = z.object({ uid: z.string().min(1) })

const queryArguments = z.object({
  datasourceUid: z.string().min(1),
  query: z.record(z.string(), z.unknown()),
  from: z.string().default("now-1h"),
  to: z.string().default("now")
})
