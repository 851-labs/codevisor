#!/usr/bin/env node
import { makeAcpRuntime } from "@herdman/acp-runtime"
import { makeDatabase } from "@herdman/db"
import { makeTerminalManager } from "@herdman/terminal"
import { Effect } from "effect"
import { defaultDatabasePath, defaultServerConfig, startHerdManServer } from "./server.js"

const parseArgs = (args: ReadonlyArray<string>): Record<string, string> => {
  const parsed: Record<string, string> = {}
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg?.startsWith("--") === true) {
      parsed[arg.slice(2)] = args[index + 1] ?? ""
      index += 1
    }
  }
  return parsed
}

const main = Effect.gen(function* () {
  const command = process.argv[2] ?? "serve"
  if (command !== "serve") {
    throw new Error(`Unsupported command: ${command}`)
  }

  const args = parseArgs(process.argv.slice(3))
  const host = args.host ?? "127.0.0.1"
  const port = Number(args.port ?? "8765")
  const serverId = args.serverId ?? "local"
  const authMode = args.auth ?? (host === "127.0.0.1" ? "none" : "token")
  if (authMode !== "none" && authMode !== "token") {
    throw new Error("--auth must be either none or token")
  }
  const db = yield* makeDatabase({
    filename: args.db ?? defaultDatabasePath(),
    serverId
  })
  const server = yield* startHerdManServer(
    {
      acp: makeAcpRuntime(),
      db,
      terminal: makeTerminalManager()
    },
    defaultServerConfig({
      host,
      id: serverId,
      kind: host === "127.0.0.1" ? "local" : "remote",
      name: args.name ?? (host === "127.0.0.1" ? "Local HerdMan" : serverId),
      port,
      auth: {
        allowLocalhostWithoutAuth: authMode === "token" && host === "127.0.0.1",
        requireBearerToken: authMode === "token"
      }
    })
  )
  console.log(`HerdMan server listening at ${server.url}`)
})

Effect.runPromise(main).catch((cause: unknown) => {
  console.error(cause instanceof Error ? cause.message : String(cause))
  process.exitCode = 1
})
