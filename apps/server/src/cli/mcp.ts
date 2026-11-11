import type { Readable, Writable } from "node:stream"

import { ExternalGateway } from "@codevisor/api"
import { type IssuedGateway, serveGatewayOverStdio } from "@codevisor/mcp"
import { Schema } from "effect"

import { field } from "../unknown-values.js"
import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"

export interface McpOptions extends CommandOptions {
  readonly project?: string | undefined
}

export interface McpSession {
  readonly input: Readable
  readonly output: Writable
  readonly disconnected: Promise<void>
}

const issueTimeoutMs = 30_000

export const mcpCommand = async (
  deps: CliDeps,
  session: McpSession,
  options: McpOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const bridge = serveGatewayOverStdio({
    version: deps.installedVersion() ?? "0.0.0-dev",
    issueGateway: (clientName) =>
      issueGateway(deps, port, { clientName, project: options.project }),
    input: session.input,
    output: session.output
  })

  await session.disconnected
  await bridge.close()
  return 0
}

const issueGateway = async (
  deps: CliDeps,
  port: number,
  body: { readonly clientName: string | undefined; readonly project: string | undefined }
): Promise<IssuedGateway> => {
  const response = await deps.fetchJson(`http://127.0.0.1:${port}/v1/mcp-gateways`, {
    method: "POST",
    body,
    timeoutMs: issueTimeoutMs
  })
  if (response === undefined) throw new Error(notRunning(port))
  if (response.status !== 201) throw new Error(refusal(response))
  return Schema.decodeUnknownSync(ExternalGateway)(response.body)
}

const notRunning = (port: number): string =>
  `Codevisor isn't running on this machine (nothing answered on port ${port}). Open the Codevisor app or run codevisor start, then try again.`

const refusal = (response: { readonly status: number; readonly body: unknown }): string => {
  const error = field(response.body, "error")
  if (typeof error === "string") return `Codevisor couldn't open a connection: ${error}`
  return `Codevisor couldn't open a connection (HTTP ${response.status})`
}
