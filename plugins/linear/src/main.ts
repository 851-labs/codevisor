import { serveStdio } from "@codevisor/plugin-kit"

import { createLinearServer } from "./linear-server.js"

await serveStdio(createLinearServer(), process.stdin, process.stdout)
