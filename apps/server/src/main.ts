#!/usr/bin/env node
import { makeAcpRuntime } from "@herdman/acp-runtime"
import { makeDatabase } from "@herdman/db"
import { makeTerminalManager } from "@herdman/terminal"
import { Effect } from "effect"
import { existsSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
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

const bundledVersion = (): string | undefined => {
  if (process.env.HERDMAN_VERSION !== undefined && process.env.HERDMAN_VERSION.length > 0) {
    return process.env.HERDMAN_VERSION
  }

  const versionPath = join(dirname(fileURLToPath(import.meta.url)), "VERSION")
  if (!existsSync(versionPath)) {
    return undefined
  }

  const version = readFileSync(versionPath, "utf8").trim()
  return version.length > 0 ? version : undefined
}

const main = Effect.gen(function* () {
  const command = process.argv[2] ?? "serve"
  if (command !== "serve") {
    throw new Error(`Unsupported command: ${command}`)
  }

  const args = parseArgs(process.argv.slice(3))
  const host = args.host ?? "127.0.0.1"
  const port = Number(args.port ?? "49361")
  const serverId = args.serverId ?? "local"
  const authMode = args.auth ?? (host === "127.0.0.1" ? "none" : "token")
  const version = args.version ?? bundledVersion()
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
      ...(version === undefined ? {} : { version }),
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
