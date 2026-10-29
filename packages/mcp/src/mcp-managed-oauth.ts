import type { McpServerRecord } from "@codevisor/db"
import type { FetchLike } from "@modelcontextprotocol/sdk/shared/transport.js"

import type { McpCatalogResolver } from "./mcp-manager-types.js"

export interface ManagedOAuthClients {
  readonly clientId: (client: string) => Promise<string>
  readonly exchange: (client: string, tokenUrl: string, form: string) => Promise<unknown>
}

export interface ManagedOAuth {
  readonly client: string
  readonly clients: ManagedOAuthClients
}

export const managedOAuthOf = (
  catalog: McpCatalogResolver | undefined,
  clients: ManagedOAuthClients | undefined,
  server: Pick<McpServerRecord, "catalogId" | "name">
): ManagedOAuth | undefined => {
  const client =
    server.catalogId === undefined ? undefined : catalog?.oauthClient?.(server.catalogId)
  if (client === undefined) return undefined
  if (clients === undefined) throw new Error(`${server.name} needs Codevisor Cloud to sign in`)
  return { client, clients }
}

export const managedTokenFetch =
  (managed: ManagedOAuth, base: FetchLike): FetchLike =>
  async (url, init) => {
    if (init?.method !== "POST") return base(url, init)
    const form = new URLSearchParams(init.body instanceof URLSearchParams ? init.body : "")
    return Response.json(
      await managed.clients.exchange(managed.client, String(url), form.toString())
    )
  }
