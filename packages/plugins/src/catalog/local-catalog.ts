import { existsSync, readdirSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { parseRegistryServer, registryServersOf, type RegistryServer } from "./registry-server.js"

export interface LocalCatalogOptions {
  readonly moduleDirectory?: string
  readonly workingDirectory?: string
}

export interface LocalCatalog {
  readonly root: string
  readonly firstParty: ReadonlyArray<RegistryServer>
  readonly popular: ReadonlyArray<RegistryServer>
}

export const popularFile = "popular.json"
export const serverFile = "server.json"

export const readLocalCatalog = (options: LocalCatalogOptions = {}): LocalCatalog => {
  const root = pluginsRoot(options)
  if (root === undefined) return { root: "", firstParty: [], popular: [] }
  return { root, firstParty: firstPartyServers(root), popular: popularServers(root) }
}

const pluginsRoot = (options: LocalCatalogOptions): string | undefined => {
  /* v8 ignore next */
  const moduleDirectory = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  return [
    join(moduleDirectory, "..", "..", "..", "..", "plugins"),
    join(workingDirectory, "plugins"),
    join(workingDirectory, "..", "..", "plugins")
  ].find((candidate) => existsSync(join(candidate, popularFile)))
}

const firstPartyServers = (root: string): ReadonlyArray<RegistryServer> =>
  readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(join(root, entry.name, serverFile)))
    .toSorted((left, right) => left.name.localeCompare(right.name))
    .flatMap((entry) => {
      const server = parseRegistryServer(readJson(join(root, entry.name, serverFile)))
      return server === undefined ? [] : [server]
    })

const popularServers = (root: string): ReadonlyArray<RegistryServer> =>
  registryServersOf(readJson(join(root, popularFile)))

const readJson = (path: string): unknown => {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as unknown
  } catch {
    return undefined
  }
}
