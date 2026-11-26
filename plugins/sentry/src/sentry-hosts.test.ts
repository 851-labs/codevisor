import { expect, it } from "vitest"

import { sentryCloudHosts } from "./sentry-api.js"
import { sentryHostsFrom } from "./sentry-hosts.js"

it("uses sentry.io unless the environment points the plugin at another Sentry", () => {
  expect(sentryHostsFrom({})).toEqual(sentryCloudHosts)
  expect(
    sentryHostsFrom({
      CODEVISOR_SENTRY_URL: "http://127.0.0.1:9400/",
      CODEVISOR_SENTRY_MCP_URL: "http://127.0.0.1:9400/mcp"
    })
  ).toEqual({ apiUrl: "http://127.0.0.1:9400", mcpUrl: "http://127.0.0.1:9400/mcp" })
})
