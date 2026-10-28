import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

import { tempDirs } from "../test-support.js"
import type { PluginCatalogOptions } from "./plugin-catalog.js"

const repositoryPlugins = fileURLToPath(new URL("../../../../plugins", import.meta.url))

const fixtureNames = ["grafana", "gmail"] as const

export const fixtureCatalogOptions = (): Pick<PluginCatalogOptions, "moduleDirectory"> => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-plugin-fixtures-"))
  tempDirs.push(root)
  const plugins = join(root, "plugins")
  mkdirSync(plugins)
  linkRepositoryPlugins(plugins)
  for (const name of fixtureNames) writeFixture(plugins, name)
  return { moduleDirectory: join(root, "packages", "plugins", "dist", "catalog") }
}

const linkRepositoryPlugins = (plugins: string): void => {
  symlinkSync(join(repositoryPlugins, "popular.json"), join(plugins, "popular.json"))
  const testEvents = join(plugins, "test-events")
  mkdirSync(testEvents)
  for (const entry of ["server.json", "dist"]) {
    symlinkSync(join(repositoryPlugins, "test-events", entry), join(testEvents, entry))
  }
}

const writeFixture = (plugins: string, name: string): void => {
  const folder = join(plugins, name)
  mkdirSync(folder)
  const server = readFileSync(new URL(`./${name}-fixture.json`, import.meta.url), "utf8")
  writeFileSync(join(folder, "server.json"), server)
}
