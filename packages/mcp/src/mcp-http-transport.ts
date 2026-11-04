import {
  type AuthProvider,
  type FetchLike,
  isJSONRPCNotification,
  isJSONRPCRequest,
  type JSONRPCMessage,
  type RequestId,
  StreamableHTTPClientTransport
} from "@modelcontextprotocol/client"

export interface StreamableHttpAuthorization {
  readonly accessToken: () => Promise<string | undefined>
  readonly recoverUnauthorized: (
    rejectedAccessToken: string | undefined
  ) => Promise<{ readonly retry: true } | { readonly retry: false; readonly reason: string }>
}

export const streamableHttpTransport = (
  url: URL,
  authorization?: string | StreamableHttpAuthorization,
  customHeaders: Readonly<Record<string, string>> = {}
): StreamableHTTPClientTransport =>
  new StreamableHTTPClientTransport(url, {
    requestInit: { headers: { ...customHeaders } },
    fetch: cancellableFetch(),
    ...authProviderOption(authorization)
  })

const authProviderOption = (
  authorization: string | StreamableHttpAuthorization | undefined
): { readonly authProvider?: AuthProvider } => {
  if (authorization === undefined) return {}
  if (typeof authorization === "string") return { authProvider: staticAuthProvider(authorization) }
  return { authProvider: renewingAuthProvider(authorization) }
}

const staticAuthProvider = (accessToken: string): AuthProvider => ({
  token: async () => accessToken,
  onUnauthorized: async ({ response }) => {
    throw unauthorized(await response.text().catch(() => response.statusText))
  }
})

const renewingAuthProvider = (authorization: StreamableHttpAuthorization): AuthProvider => {
  let presented: string | undefined
  return {
    token: async () => {
      presented = await authorization.accessToken()
      return presented
    },
    onUnauthorized: async () => {
      const recovery = await authorization.recoverUnauthorized(presented)
      if (!recovery.retry) throw unauthorized(recovery.reason)
    }
  }
}

const unauthorized = (reason: string): Error => new Error(`Streamable HTTP error 401: ${reason}`)

const cancellableFetch = (): FetchLike => {
  const inFlight = new Map<RequestId, AbortController>()

  return async (url, init) => {
    const message = sentMessage(init?.body)
    const cancelled = cancelledRequestId(message)
    if (cancelled !== undefined) return fetchThenAbort(url, init, inFlight.get(cancelled))
    if (message === undefined || !isJSONRPCRequest(message)) return fetch(url, init)

    const request = new AbortController()
    inFlight.set(message.id, request)
    const settle = () => inFlight.delete(message.id)
    try {
      return settleWithBody(await fetch(url, withSignal(init, request.signal)), settle)
    } catch (cause) {
      settle()
      throw cause
    }
  }
}

const fetchThenAbort = async (
  url: string | URL,
  init: RequestInit | undefined,
  request: AbortController | undefined
): Promise<Response> => {
  try {
    return await fetch(url, init)
  } finally {
    request?.abort()
  }
}

const withSignal = (init: RequestInit | undefined, signal: AbortSignal): RequestInit => {
  const transportSignal = init?.signal ?? undefined
  if (transportSignal === undefined) return { ...init, signal }
  return { ...init, signal: AbortSignal.any([transportSignal, signal]) }
}

const settleWithBody = (response: Response, settle: () => void): Response => {
  if (response.body === null) {
    settle()
    return response
  }
  const body = response.body.pipeThrough(new TransformStream({ flush: settle }))
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers
  })
}

const sentMessage = (body: RequestInit["body"]): JSONRPCMessage | undefined => {
  if (typeof body !== "string") return undefined
  try {
    const decoded: unknown = JSON.parse(body)
    if (isJSONRPCRequest(decoded) || isJSONRPCNotification(decoded)) return decoded
    return undefined
  } catch {
    return undefined
  }
}

const cancelledRequestId = (message: JSONRPCMessage | undefined): RequestId | undefined => {
  if (message === undefined || !isJSONRPCNotification(message)) return undefined
  if (message.method !== "notifications/cancelled") return undefined

  const requestId: unknown = message.params?.requestId
  if (typeof requestId === "string" || typeof requestId === "number") return requestId
  return undefined
}
