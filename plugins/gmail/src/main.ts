import { serveStdio } from "@codevisor/plugin-kit"

import { createGmailServer } from "./gmail-server.js"

await serveStdio(createGmailServer(), process.stdin, process.stdout)
