import { serveStdio } from "@codevisor/plugin-kit"

import { sentryHostsFrom } from "./sentry-hosts.js"
import { createSentryServer } from "./sentry-server.js"

await serveStdio(
  createSentryServer({ hosts: sentryHostsFrom(process.env) }),
  process.stdin,
  process.stdout
)
