import { Hono } from "hono"

import { userHub } from "./location-hint.js"
import { requireMachine, type MachineEnv } from "./machine-auth.js"

export const roleRoutes = new Hono<MachineEnv>()

roleRoutes.use("/api/machine/roles", requireMachine)

roleRoutes.get("/api/machine/roles", async (c) => {
  const roles = await userHub(c.env, c.var.machine.userId, c.req.raw.cf).roleStatus()
  c.header("Cache-Control", "no-store")
  return c.json({ roles })
})
