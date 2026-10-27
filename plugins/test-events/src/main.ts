import { serveStdio } from "@codevisor/plugin-kit"

import { createTestEventsServer, testEventsOptionsFromEnv } from "./test-events-server.js"

await serveStdio(
  createTestEventsServer(testEventsOptionsFromEnv(process.env)),
  process.stdin,
  process.stdout
)
