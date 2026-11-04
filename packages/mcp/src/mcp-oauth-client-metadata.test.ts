import { describe, expect, it } from "vitest"

import { clientMetadataUrlFor, codevisorClientMetadataUrl } from "./mcp-oauth-client-metadata.js"

const server = (registration: { readonly registration_endpoint?: string }) => ({
  issuer: "https://auth.example.com",
  authorization_endpoint: "https://auth.example.com/authorize",
  token_endpoint: "https://auth.example.com/token",
  response_types_supported: ["code"],
  ...registration
})

const withoutRegistration = server({})
const withRegistration = server({ registration_endpoint: "https://auth.example.com/register" })

describe("Codevisor's OAuth client metadata document", () => {
  it("names Codevisor's document for loopback callbacks on any port when registration is missing", () => {
    expect(
      [
        "http://127.0.0.1:49361/v1/mcps/oauth/callback",
        "http://localhost:56036/v1/mcps/oauth/callback"
      ].map((callback) => clientMetadataUrlFor(callback, withoutRegistration))
    ).toEqual([codevisorClientMetadataUrl, codevisorClientMetadataUrl])
  })

  it("keeps dynamic registration where the server offers it, and for non-loopback callbacks", () => {
    expect(
      clientMetadataUrlFor("http://127.0.0.1:49361/v1/mcps/oauth/callback", withRegistration)
    ).toBeUndefined()
    expect(
      clientMetadataUrlFor("http://192.168.1.20:49361/v1/mcps/oauth/callback", withoutRegistration)
    ).toBeUndefined()
  })
})
