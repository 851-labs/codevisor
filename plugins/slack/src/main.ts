import { serveStdio } from "@codevisor/plugin-kit"

import { createSlackServer } from "./slack-server.js"

await serveStdio(createSlackServer(), process.stdin, process.stdout)
