// @boundaries-ignore the Worker bundles the API package from source.
import { CredentialCommand, decode } from "@codevisor/api"
import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"

import { createAuth } from "./auth.js"
import type { CloudEnv } from "./env.js"
import { hubLocationHint } from "./location-hint.js"
import type { UserHub } from "./user-hub.js"

export const credentialRoutes = new Hono<{ Bindings: CloudEnv }>()

credentialRoutes.post(
  "/api/machine/credentials/:id",
  bodyLimit({ maxSize: 100_000 }),
  async (c) => {
    const id = c.req.param("id")
    if (!/^[a-zA-Z0-9_-]{16,100}$/.test(id)) return c.json({ error: "invalid credential id" }, 400)
    const key = c.req.header("x-api-key")
    if (key === undefined) return c.json({ error: "missing credential" }, 401)
    const verified = await createAuth(c.env).api.verifyApiKey({ body: { key } })
    const metadata = verified.key?.metadata as { deviceId?: string } | null | undefined
    if (!verified.valid || verified.key == null || typeof metadata?.deviceId !== "string") {
      return c.json({ error: "invalid machine credential" }, 401)
    }
    const expectedAccount = c.req.header("x-codevisor-account")
    if (expectedAccount !== undefined && expectedAccount !== verified.key.referenceId) {
      return c.json({ error: "credential belongs to another account" }, 409)
    }
    const raw = await c.req.text()
    let command: CredentialCommand
    try {
      command = decode(CredentialCommand)(JSON.parse(raw))
      if ("operationId" in command && !/^[a-zA-Z0-9_-]{16,100}$/.test(command.operationId))
        throw new Error()
      if (
        "generation" in command &&
        (!Number.isSafeInteger(command.generation) || command.generation < 1)
      )
        throw new Error()
      if ("sealed" in command && (command.sealed.length < 40 || command.sealed.length > 90_000))
        throw new Error()
    } catch {
      return c.json({ error: "invalid credential command" }, 400)
    }
    const locationHint = hubLocationHint(c.req.raw.cf)
    const hub = (c.env.USER_HUB as unknown as DurableObjectNamespace<UserHub>).getByName(
      verified.key.referenceId,
      locationHint === undefined ? undefined : { locationHint }
    )
    c.header("Cache-Control", "no-store")
    c.header("X-Codevisor-Account", verified.key.referenceId)
    return c.json(await hub.credentialCommand(id, metadata.deviceId, command))
  }
)
