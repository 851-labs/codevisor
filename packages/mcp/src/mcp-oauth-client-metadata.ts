import type { AuthorizationServerMetadata } from "@modelcontextprotocol/sdk/shared/auth.js"

export const codevisorClientMetadataUrl = "https://www.codevisor.dev/oauth/client-metadata.json"

export const clientMetadataUrlFor = (
  redirectUrl: string,
  authorizationServer: AuthorizationServerMetadata | undefined
): string | undefined =>
  lacksRegistration(authorizationServer) && isLoopbackCallback(new URL(redirectUrl))
    ? codevisorClientMetadataUrl
    : undefined

const lacksRegistration = (server: AuthorizationServerMetadata | undefined): boolean =>
  server !== undefined && server.registration_endpoint === undefined

const isLoopbackCallback = (url: URL): boolean =>
  url.protocol === "http:" && loopbackHosts.has(url.hostname)

const loopbackHosts: ReadonlySet<string> = new Set(["127.0.0.1", "localhost"])
