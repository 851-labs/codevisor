import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"

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

const catalog = { firstParty: serverJsonFiles().map(readJson), popular: popularServers() }

mkdirSync(path.dirname(outputFile), { recursive: true })
writeFileSync(outputFile, `${JSON.stringify(catalog, null, 2)}\n`)
