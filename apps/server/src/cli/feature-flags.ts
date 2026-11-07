import { FeatureFlagsResponse, FeatureFlagState } from "@codevisor/api"
import { Schema } from "effect"

import { resolvePort, routeFailure, type CliDeps, type CommandOptions } from "./support.js"

const flagsUrl = (port: number, path = ""): string =>
  `http://127.0.0.1:${port}/v1/feature-flags${path}`

const onOff = (enabled: boolean): string => (enabled ? "on" : "off")

export const flagsListCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(flagsUrl(port))
  if (response?.status !== 200) {
    deps.error(`Couldn't list feature flags: ${routeFailure(response, port)}`)
    return 1
  }
  const { flags } = Schema.decodeUnknownSync(FeatureFlagsResponse)(response.body)
  const width = Math.max(...flags.map((flag) => flag.id.length))
  for (const flag of flags) {
    deps.log(`${flag.id.padEnd(width)}  ${onOff(flag.enabled).padEnd(3)}  ${flag.description}`)
  }
  return 0
}

export const flagsSetCommand = async (
  deps: CliDeps,
  options: CommandOptions & { readonly flag: string; readonly enabled: boolean }
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(flagsUrl(port, `/${encodeURIComponent(options.flag)}`), {
    method: "PUT",
    body: { enabled: options.enabled }
  })
  if (response?.status !== 200) {
    deps.error(
      `Couldn't turn ${options.flag} ${onOff(options.enabled)}: ${routeFailure(response, port)}`
    )
    return 1
  }
  const flag = Schema.decodeUnknownSync(FeatureFlagState)(response.body)
  deps.log(
    `✓ ${flag.title} is ${onOff(flag.enabled)}. Your Codevisor apps sync it to your other machines.`
  )
  return 0
}
