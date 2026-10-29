import { readFile } from "node:fs/promises"
import { join } from "node:path"

import { recordField, stringField } from "../../unknown-values.js"
import type { OAuthClient } from "./plugin-account-oauth.js"

export type InstalledOAuthClients = (provider: string) => Promise<OAuthClient | undefined>

export interface InstalledOAuthClientsOptions {
  readonly env: NodeJS.ProcessEnv
  readonly dev: boolean
  readonly home: string
  readonly runtimeRoot: string
}

export const installedClientSources: ReadonlyMap<string, InstalledClientSource> = new Map([
  [
    "google",
    {
      envVar: "CODEVISOR_GOOGLE_OAUTH_CLIENT_FILE",
      bundledFile: join("config", "google-oauth-client.json"),
      devFile: join(".codevisor-dev-secrets", "google-gmail-dev-oauth-client.json")
    }
  ]
])

export const installedOAuthClients =
  (options: InstalledOAuthClientsOptions): InstalledOAuthClients =>
  async (provider) => {
    for (const path of clientFilePaths(installedClientSources.get(provider), options)) {
      const client = parseInstalledClient(await readJson(path))
      if (client !== undefined) return client
    }
    return undefined
  }

export const noInstalledOAuthClients: InstalledOAuthClients = async () => undefined

interface InstalledClientSource {
  readonly envVar: string
  readonly bundledFile: string
  readonly devFile: string
}

const clientFilePaths = (
  source: InstalledClientSource | undefined,
  options: InstalledOAuthClientsOptions
): ReadonlyArray<string> => {
  if (source === undefined) return []

  const configured = options.env[source.envVar]
  return [
    ...(configured === undefined || configured === "" ? [] : [configured]),
    join(options.runtimeRoot, source.bundledFile),
    ...(options.dev ? [join(options.home, source.devFile)] : [])
  ]
}

const readJson = async (path: string): Promise<unknown> => {
  try {
    return JSON.parse(await readFile(path, "utf8")) as unknown
  } catch {
    return undefined
  }
}

const parseInstalledClient = (file: unknown): OAuthClient | undefined => {
  const installed = recordField(file, "installed")
  const clientId = stringField(installed, "client_id")
  if (clientId === undefined || clientId === "") return undefined

  const clientSecret = stringField(installed, "client_secret")
  return { clientId, ...(clientSecret === undefined ? {} : { clientSecret }) }
}
