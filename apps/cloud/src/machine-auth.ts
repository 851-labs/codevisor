import { createMiddleware } from "hono/factory"

import { verifyMachineKey } from "./credential-routes.js"
import type { CloudEnv } from "./env.js"

export interface AuthenticatedMachine {
  readonly userId: string
  readonly deviceId: string
}

export interface MachineEnv {
  Bindings: CloudEnv
  Variables: { machine: AuthenticatedMachine }
}

export const requireMachine = createMiddleware<MachineEnv>(async (c, next) => {
  const machine = await verifyMachineKey(c.env, c.req.header("x-api-key"))
  if (machine === undefined) return c.json({ error: "invalid machine credential" }, 401)

  c.set("machine", machine)
  return next()
})
