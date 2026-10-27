import { serveStdio } from "@codevisor/plugin-kit"

import { createGrafanaServer } from "./grafana-server.js"

await serveStdio(createGrafanaServer(), process.stdin, process.stdout)
