import { createHash, randomBytes, randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"

import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"
import { attempt } from "./errors.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeAuthService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "issuePairingToken"
  | "verifyBearerToken"
  | "getOrCreateInstanceId"
  | "getOrCreateConnectionToken"
  | "rotateConnectionToken"
> => {
  const { sqlite } = context

  return {
    issuePairingToken: attempt("issuePairingToken", () => {
      const token = `hm_${randomBytes(24).toString("base64url")}`
      insertAdminToken(sqlite, token)
      return token
    }),
    verifyBearerToken: (token) =>
      attempt("verifyBearerToken", () => {
        return tokenExists(sqlite, token)
      }),
    getOrCreateInstanceId: attempt("getOrCreateInstanceId", () => {
      const existing = readInstanceMeta(sqlite, "machine-id")
      if (existing !== undefined) return existing
      const id = randomUUID()
      sqlite.prepare(instanceMetaSql.insertMachineId).run(id)
      return id
    }),
    getOrCreateConnectionToken: attempt("getOrCreateConnectionToken", () => {
      const existing = readInstanceMeta(sqlite, "connection-token")
      if (existing !== undefined) return existing
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const create = sqlite.transaction(() => {
        sqlite.prepare(connectionTokenSql.insert).run(token)
        insertAdminToken(sqlite, token)
      })
      create()
      return token
    }),
    rotateConnectionToken: attempt("rotateConnectionToken", () => {
      const existing = readInstanceMeta(sqlite, "connection-token")
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const rotate = sqlite.transaction(() => {
        if (existing !== undefined) {
          sqlite.prepare(authTokenSql.deleteByHash).run(hashToken(existing))
        }
        sqlite.prepare(connectionTokenSql.upsert).run(token)
        insertAdminToken(sqlite, token)
      })
      rotate()
      return token
    })
  }
}

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")

const insertAdminToken = (sqlite: ServiceContext["sqlite"], token: string): void => {
  sqlite.prepare(authTokenSql.insert).run(randomUUID(), hashToken(token), "admin", isoTimestamp())
}

const tokenExists = (sqlite: ServiceContext["sqlite"], token: string): boolean =>
  sqlite.prepare(authTokenSql.idByHash).get(hashToken(token)) !== undefined

const authTokenSql = {
  insert: "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)",
  idByHash: "select id from auth_tokens where token_hash = ?",
  deleteByHash: "delete from auth_tokens where token_hash = ?"
}

const connectionTokenSql = {
  insert: "insert into instance_meta (key, value) values ('connection-token', ?)",
  upsert: `insert into instance_meta (key, value) values ('connection-token', ?)
             on conflict(key) do update set value = excluded.value`
}
