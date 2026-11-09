import { spawn } from "node:child_process"
import { networkInterfaces } from "node:os"

import { captureCommand } from "./commands.ts"

export interface InterfaceAddress {
  readonly family: string
  readonly address: string
  readonly internal: boolean
}

export interface VmHostProbes {
  readonly tartInstalled?: () => Promise<boolean>
  readonly defaultRoute?: () => Promise<string | undefined>
  readonly interfaces?: () => NodeJS.Dict<ReadonlyArray<InterfaceAddress>>
}

export async function resolveDevVmHost({
  tartInstalled = isTartInstalled,
  defaultRoute = defaultRouteInterface,
  interfaces = networkInterfaces
}: VmHostProbes = {}): Promise<string | undefined> {
  if (!(await tartInstalled())) return undefined

  const name = await defaultRoute()
  if (name === undefined) return undefined

  return interfaces()[name]?.find((address) => address.family === "IPv4" && !address.internal)
    ?.address
}

export function parseDefaultRouteInterface(output: string): string | undefined {
  return /^\s*interface:\s*(\S+)/m.exec(output)?.[1]
}

function isTartInstalled(): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn("tart", ["--version"], { stdio: "ignore" })
    child.on("error", () => resolve(false))
    child.on("exit", (code) => resolve(code === 0))
  })
}

async function defaultRouteInterface(): Promise<string | undefined> {
  return parseDefaultRouteInterface(
    await captureCommand("/sbin/route", ["-n", "get", "default"]).catch(() => "")
  )
}
