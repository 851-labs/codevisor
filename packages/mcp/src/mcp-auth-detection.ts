import type { McpAuthDetection } from "@codevisor/api"
import { discoverOAuthProtectedResourceMetadata } from "@modelcontextprotocol/sdk/client/auth.js"
import { requireHttpUrl, suggestedMcpName } from "./mcp-support.js"

/// Probes an HTTP MCP endpoint with a bare initialize request and classifies
/// its authorization challenge: none, OAuth (protected-resource metadata),
/// or a plain bearer token.
export const detectMcpAuth = async (value: string): Promise<McpAuthDetection> => {
  const url = requireHttpUrl(value)
  const parsedUrl = new URL(url)
  const fallbackName = suggestedMcpName(parsedUrl)
  const response = await fetch(url, {
    method: "POST",
    signal: AbortSignal.timeout(5_000),
    headers: {
      accept: "application/json, text/event-stream",
      "content-type": "application/json"
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: "codevisor-auth-detection",
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "Codevisor", version: "0.1.0" }
      }
    })
  })
  const challenge = response.headers.get("www-authenticate")?.toLowerCase() ?? ""
  /* v8 ignore next -- best-effort cleanup after reading only the authorization challenge. */
  await response.body?.cancel().catch(() => undefined)
  if (response.status !== 401 && response.status !== 403) {
    return {
      authType: "none",
      detail: "No authorization challenge detected",
      suggestedName: fallbackName
    }
  }
  if (challenge.includes("resource_metadata=")) {
    return {
      authType: "oauth",
      detail: "OAuth protected resource detected",
      suggestedName: fallbackName
    }
  }
  try {
    await discoverOAuthProtectedResourceMetadata(new URL(url))
    return {
      authType: "oauth",
      detail: "OAuth protected resource detected",
      suggestedName: fallbackName
    }
  } catch {
    return {
      authType: "bearer",
      detail: challenge.includes("bearer")
        ? "Bearer token authorization detected"
        : "Authorization required; bearer token selected",
      suggestedName: fallbackName
    }
  }
}
