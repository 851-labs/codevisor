import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"

import { z } from "zod"

const pluginsDir = path.resolve(import.meta.dirname, "../../../plugins")
const outputFile = path.resolve(import.meta.dirname, "../src/generated/plugin-catalog.json")

const readJson = (file: string): unknown => JSON.parse(readFileSync(file, "utf8"))

const serverJsonFiles = (): string[] =>
  readdirSync(pluginsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(pluginsDir, entry.name, "server.json"))
    .filter((file) => existsSync(file))
    .toSorted()

const popularServers = (): unknown => readJson(path.join(pluginsDir, "popular.json"))

const DevOnlyServer = z.object({
  _meta: z.object({ "dev.codevisor/plugin": z.object({ devOnly: z.literal(true) }) })
})

const isDevOnly = (server: unknown): boolean => DevOnlyServer.safeParse(server).success

const firstPartyServers = (): unknown[] =>
  serverJsonFiles()
    .map(readJson)
    .filter((server) => !isDevOnly(server))

const catalog = { firstParty: firstPartyServers(), popular: popularServers() }

mkdirSync(path.dirname(outputFile), { recursive: true })
writeFileSync(outputFile, `${JSON.stringify(catalog, null, 2)}\n`)
