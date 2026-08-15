import { isoTimestamp } from "@codevisor/api"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makeAuthService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "issuePairingToken"
  | "verifyBearerToken"
  | "getOrCreateInstanceId"
  | "getOrCreateConnectionToken"
  | "rotateConnectionToken"
  | "getBrowserPreference"
  | "setBrowserPreference"
> => {
  const { sqlite } = context

  return {
    issuePairingToken: attempt("issuePairingToken", () => {
      const token = `hm_${randomBytes(24).toString("base64url")}`
      sqlite
        .prepare("insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)")
        .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      return token
    }),
    verifyBearerToken: (token) =>
      attempt("verifyBearerToken", () => {
        const row = sqlite
          .prepare("select id from auth_tokens where token_hash = ?")
          .get(hashToken(token))
        return row !== undefined
      }),
    getOrCreateInstanceId: attempt("getOrCreateInstanceId", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'machine-id'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      const id = randomUUID()
      sqlite.prepare("insert into instance_meta (key, value) values ('machine-id', ?)").run(id)
      return id
    }),
    getOrCreateConnectionToken: attempt("getOrCreateConnectionToken", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      // Stable across restarts and updates: the plaintext lives in
      // instance_meta so it can be shown again, and its hash goes in
      // auth_tokens so verifyBearerToken accepts it like any pairing token.
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const create = sqlite.transaction(() => {
        sqlite
          .prepare("insert into instance_meta (key, value) values ('connection-token', ?)")
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      create()
      return token
    }),
    rotateConnectionToken: attempt("rotateConnectionToken", () => {
      const existing = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const rotate = sqlite.transaction(() => {
        if (existing !== undefined) {
          // Retire the old token so previously paired clients must re-pair.
          sqlite
            .prepare("delete from auth_tokens where token_hash = ?")
            .run(hashToken(existing.value))
        }
        sqlite
          .prepare(
            `insert into instance_meta (key, value) values ('connection-token', ?)
             on conflict(key) do update set value = excluded.value`
          )
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      rotate()
      return token
    }),
    getBrowserPreference: attempt("getBrowserPreference", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'browser-preference'")
        .get() as { readonly value: string } | undefined
      return row?.value === "chrome" || row?.value === "managed" ? row.value : undefined
    }),
    setBrowserPreference: (preference) =>
      attempt("setBrowserPreference", () => {
        if (preference === undefined) {
          sqlite.prepare("delete from instance_meta where key = 'browser-preference'").run()
          return
        }
        sqlite
          .prepare(
            `insert into instance_meta (key, value) values ('browser-preference', ?)
             on conflict(key) do update set value = excluded.value`
          )
          .run(preference)
      })
  }
}

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")
