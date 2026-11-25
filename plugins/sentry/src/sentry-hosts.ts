import { sentryCloudHosts, type SentryHosts } from "./sentry-api.js"

export const sentryHostsFrom = (env: Record<string, string | undefined>): SentryHosts => ({
  apiUrl: withoutTrailingSlash(env.CODEVISOR_SENTRY_URL) ?? sentryCloudHosts.apiUrl,
  mcpUrl: env.CODEVISOR_SENTRY_MCP_URL || sentryCloudHosts.mcpUrl
})

const withoutTrailingSlash = (url: string | undefined): string | undefined =>
  url === undefined || url === "" ? undefined : url.replace(/\/+$/, "")
