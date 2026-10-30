import { describe, expect, it } from "vitest"

import { redactSecrets } from "./redact-secrets.js"

describe("redactSecrets", () => {
  it("hides tokens, keys and credentials in harness output while keeping the rest readable", () => {
    expect(
      redactSecrets(
        [
          "OAuth token sk-ant-oat01-abc_DEF-123 expired",
          "Authorization: Bearer abc.def-ghi",
          "jwt eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl",
          "fetch https://user:pw@api.example.com/v1 failed",
          'refresh_token="r-123" api-key=k_456 client_secret: s789',
          "exited with code 1"
        ].join("\n")
      )
    ).toBe(
      [
        "OAuth token sk-ant-<redacted> expired",
        "Authorization: <redacted> <redacted>",
        "jwt <redacted-jwt>",
        "fetch https://<redacted>@api.example.com/v1 failed",
        'refresh_token="<redacted>" api-key=<redacted> client_secret: <redacted>',
        "exited with code 1"
      ].join("\n")
    )
  })
})
