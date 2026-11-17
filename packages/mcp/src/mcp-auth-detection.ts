import type { McpAuthDetection } from "@codevisor/api"
import {
  discoverOAuthProtectedResourceMetadata,
  discoverOAuthServerInfo,
  type OAuthDiscoveryState
} from "@modelcontextprotocol/client"

import { requireHttpUrl, suggestedMcpName } from "./mcp-support.js"

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
  /* v8 ignore next */
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

export interface OAuthDiscoveries {
  readonly prepare: (url: string) => Promise<boolean>
  readonly recent: (url: string) => OAuthDiscoveryState | undefined
}

export const makeOAuthDiscoveries = (now: () => number = Date.now): OAuthDiscoveries => {
  const found = new Map<string, { readonly state: OAuthDiscoveryState; readonly at: number }>()
  return {
    prepare: async (value) => {
      const url = requireHttpUrl(value)
      const state = await discoverOAuthServerInfo(url, { fetchFn: withinDetectionTime }).catch(
        () => undefined
      )
      if (state?.resourceMetadata === undefined) return false

      found.set(url, { state, at: now() })
      return true
    },
    recent: (value) => {
      const discovery = found.get(requireHttpUrl(value))
      if (discovery === undefined || now() - discovery.at > discoveryFreshMs) return undefined
      return discovery.state
    }
  }
}

const discoveryFreshMs = 10 * 60_000

const withinDetectionTime: typeof fetch = (input, init) =>
  fetch(input, { ...init, signal: AbortSignal.timeout(5_000) })
