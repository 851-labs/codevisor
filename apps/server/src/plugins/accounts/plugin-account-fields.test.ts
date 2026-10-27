import type { ConfigField } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { splitFieldValues } from "./plugin-account-fields.js"

const field = (
  overrides: Partial<ConfigField> & Pick<ConfigField, "key" | "type">
): ConfigField => ({
  label: overrides.key.toUpperCase(),
  required: false,
  ...overrides
})

const refused = (status: number, message: string) => expect.objectContaining({ status, message })

describe("plugin account fields", () => {
  it("keeps secrets apart from the values that sync, normalizing what was typed", () => {
    const fields = [
      field({ key: "url", type: "url", required: true }),
      field({ key: "token", type: "secret", required: true }),
      field({ key: "port", type: "number", min: 1, max: 65_535 }),
      field({ key: "tls", type: "boolean" }),
      field({ key: "region", type: "choice", choices: [{ value: "eu", label: "Europe" }] }),
      field({ key: "team", type: "string", default: "core" }),
      field({ key: "host", type: "machine" }),
      field({ key: "note", type: "string" })
    ]

    const split = splitFieldValues(fields, {
      url: " https://grafana.example.com// ",
      token: "glsa_secret",
      port: "3000",
      tls: "false",
      region: "eu",
      host: "studio",
      note: null
    })

    expect(split).toEqual({
      values: {
        url: "https://grafana.example.com",
        port: 3000,
        tls: false,
        region: "eu",
        team: "core",
        host: "studio"
      },
      secrets: { token: "glsa_secret" }
    })
  })

  it("keeps a stored secret left blank and generates one that was never set", () => {
    const fields = [
      field({ key: "token", type: "secret", required: true }),
      field({ key: "webhookSecret", type: "secret", generated: true })
    ]

    const kept = splitFieldValues(fields, { token: "" }, { token: "stored", webhookSecret: "kept" })
    const generated = splitFieldValues(fields, { token: "new" })

    expect(kept.secrets).toEqual({ token: "stored", webhookSecret: "kept" })
    expect(generated.secrets.webhookSecret).toMatch(/^[\w-]{32}$/)
  })

  it("only asks for fields whose condition holds", () => {
    const fields = [
      field({
        key: "auth",
        type: "choice",
        choices: [
          { value: "token", label: "Token" },
          { value: "none", label: "None" }
        ]
      }),
      field({
        key: "token",
        type: "secret",
        required: true,
        when: { key: "auth", op: "eq", value: "token" }
      }),
      field({
        key: "anonymous",
        type: "boolean",
        required: true,
        when: { key: "auth", op: "neq", value: "token" }
      })
    ]

    const withToken = splitFieldValues(fields, { auth: "token", token: "t", anonymous: "ignored" })
    const withoutToken = splitFieldValues(fields, {
      auth: "none",
      token: "ignored",
      anonymous: true
    })

    expect(withToken).toEqual({ values: { auth: "token" }, secrets: { token: "t" } })
    expect(withoutToken).toEqual({ values: { auth: "none", anonymous: true }, secrets: {} })
  })

  it.each([
    {
      name: "a missing required field",
      field: field({ key: "url", type: "url", required: true }),
      value: "  ",
      problem: "URL is required"
    },
    {
      name: "a non-number",
      field: field({ key: "port", type: "number" }),
      value: "many",
      problem: "PORT must be a number"
    },
    {
      name: "a number below its minimum",
      field: field({ key: "port", type: "number", min: 1 }),
      value: 0,
      problem: "PORT must be at least 1"
    },
    {
      name: "a number above its maximum",
      field: field({ key: "port", type: "number", max: 9 }),
      value: 10,
      problem: "PORT must be at most 9"
    },
    {
      name: "a non-boolean",
      field: field({ key: "tls", type: "boolean" }),
      value: "yes",
      problem: "TLS must be true or false"
    },
    {
      name: "a non-http URL",
      field: field({ key: "url", type: "url" }),
      value: "ftp://grafana",
      problem: "URL must be an http or https URL"
    },
    {
      name: "an unparseable URL",
      field: field({ key: "url", type: "url" }),
      value: "grafana",
      problem: "URL must be an http or https URL"
    },
    {
      name: "an unknown choice",
      field: field({ key: "region", type: "choice", choices: [] }),
      value: "us",
      problem: "REGION isn't one of the choices"
    },
    {
      name: "a choice without choices",
      field: field({ key: "region", type: "choice" }),
      value: "us",
      problem: "REGION isn't one of the choices"
    },
    {
      name: "a number where text belongs",
      field: field({ key: "team", type: "string" }),
      value: 7,
      problem: "TEAM must be text"
    }
  ])("refuses $name", ({ field: refusedField, value, problem }) => {
    expect(() => splitFieldValues([refusedField], { [refusedField.key]: value })).toThrow(
      refused(400, problem)
    )
  })
})
