#!/usr/bin/env node
import { parseArgs, runServe } from "./serve.js"

const USAGE = `codevisor-server — Codevisor server

Usage: codevisor-server [serve] [options]

Options:
  --host <address>         Address to bind (default: 127.0.0.1)
  --port <port>            Port to listen on (default: 49361)
  --name <name>            Server display name (default: "Local Codevisor" or hostname)
  --serverId <id>          Server identifier (default: local)
  --auth <none|token>      Auth mode (default: none on 127.0.0.1, token otherwise)
  --kind <kind>            Server kind
  --cors-origins <list>    Comma-separated allowed CORS origins
  --db <path>              Database path (default: canonical data directory)
  --upgrade-status <path>  Data-upgrade status file path
  --boot-id <id>           Unique identity for this server startup
  --app-owned <0|1>        Tie this server to a desktop app
  --owner-pid <pid>        Owning desktop app process identifier
  --service-managed <0|1>  Run as the desktop app's managed background service
  -h, --help               Print this help and exit
`

const args = process.argv.slice(2)
const command = args[0] ?? "serve"
const wantsHelp = command === "help" || args.some((arg) => arg === "--help" || arg === "-h")

if (wantsHelp) {
  console.log(USAGE)
} else if (command !== "serve") {
  console.error(`Unsupported command: ${command}`)
  console.error(USAGE)
  process.exitCode = 1
} else {
  void runServe(parseArgs(args.slice(1)))
}
