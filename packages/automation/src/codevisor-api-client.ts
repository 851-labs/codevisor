import type { AutomationProviderContext } from "./automation-provider.js"
import { bearerHeaders, loopbackBaseUrl } from "./codevisor-api-request.js"
import { responseError } from "./codevisor-api-response.js"
import type { HttpMethod } from "./codevisor-api-tool-spec.js"

export interface CodevisorApiRequest {
  readonly query?: Readonly<Record<string, string | undefined>>
  readonly body?: unknown
}

export type CodevisorApi = (
  method: HttpMethod,
  path: string,
  request?: CodevisorApiRequest
) => Promise<unknown>

export interface CodevisorApiConnection {
  readonly getBaseUrl: () => string
  readonly getBearerToken: () => Promise<string>
}

export const makeCodevisorApi =
  (
    connection: CodevisorApiConnection,
    context: AutomationProviderContext,
    toolName: string
  ): CodevisorApi =>
  async (method, path, request = {}) => {
    const url = requestUrl(connection, path, request.query)
    const response = await fetch(url, await requestInit(connection, context, method, request))
    if (!response.ok) throw await responseError({ name: toolName }, response)
    const text = await response.text()
    return text.length === 0 ? undefined : (JSON.parse(text) as unknown)
  }

const requestUrl = (
  connection: CodevisorApiConnection,
  path: string,
  query: CodevisorApiRequest["query"]
): URL => {
  const url = new URL(path, loopbackBaseUrl(connection.getBaseUrl()))
  for (const [name, value] of Object.entries(query ?? {})) {
    if (value !== undefined) url.searchParams.set(name, value)
  }
  return url
}

const requestInit = async (
  connection: CodevisorApiConnection,
  context: AutomationProviderContext,
  method: HttpMethod,
  request: CodevisorApiRequest
): Promise<RequestInit> => {
  const headers = bearerHeaders(await connection.getBearerToken(), context)
  if (request.body !== undefined) headers.set("content-type", "application/json")
  return {
    method,
    headers,
    ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
    ...(context.signal === undefined ? {} : { signal: context.signal })
  }
}
