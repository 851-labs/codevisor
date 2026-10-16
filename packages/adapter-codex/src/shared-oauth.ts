import type { HarnessAccountContext } from "@codevisor/agent-runtime"

import type { CodexClient } from "./client.js"
import { isRecord } from "./internal.js"

class CodexSignInRequired extends Error {
  readonly kind = "authRequired"
}

export const connectSharedCodexAccount = async (
  client: CodexClient,
  oauth: NonNullable<HarnessAccountContext["oauth"]>
): Promise<CodexClient> => {
  let current = await oauth.token()
  if (!current.accountId)
    throw new CodexSignInRequired("This ChatGPT account needs to be reconnected")
  let rejected = false
  let handler: Parameters<CodexClient["onRequest"]>[0] | undefined
  client.onRequest(async (method, params, signal) => {
    if (method !== "account/chatgptAuthTokens/refresh") {
      if (!handler) throw new Error("Unsupported Codex request")
      return handler(method, params, signal)
    }
    signal.throwIfAborted()
    const previousAccountId = isRecord(params) ? params.previousAccountId : undefined
    if (previousAccountId && previousAccountId !== current.accountId)
      throw new Error("ChatGPT account changed; reconnect this chat")
    const next = await oauth.token(current.accessToken).catch((cause: unknown) => {
      if (isRecord(cause) && (cause.reason === "reauthenticate" || cause.reason === "revoked"))
        rejected = true
      throw cause
    })
    signal.throwIfAborted()
    if (!next.accountId || next.accountId !== current.accountId)
      throw new Error("ChatGPT account changed; reconnect this chat")
    current = next
    return {
      accessToken: next.accessToken,
      chatgptAccountId: next.accountId,
      ...(next.planType ? { chatgptPlanType: next.planType } : {})
    }
  })
  await client.request("account/login/start", {
    type: "chatgptAuthTokens",
    accessToken: current.accessToken,
    chatgptAccountId: current.accountId,
    ...(current.planType ? { chatgptPlanType: current.planType } : {})
  })
  return {
    ...client,
    request: async <T>(method: string, params?: unknown): Promise<T> => {
      if (method === "turn/start") {
        rejected = false
        const next = await oauth.token()
        if (!next.accountId || next.accountId !== current.accountId)
          throw new Error("ChatGPT account changed; reconnect this chat")
        if (next.accessToken !== current.accessToken) {
          await client.request("account/login/start", {
            type: "chatgptAuthTokens",
            accessToken: next.accessToken,
            chatgptAccountId: next.accountId,
            ...(next.planType ? { chatgptPlanType: next.planType } : {})
          })
          current = next
        }
      }
      return client.request<T>(method, params)
    },
    notify: client.notify.bind(client),
    onNotification: client.onNotification.bind(client),
    onClose: client.onClose.bind(client),
    close: client.close.bind(client),
    ...(client.closeAndWait ? { closeAndWait: client.closeAndWait.bind(client) } : {}),
    authRejected: () => rejected,
    onRequest: (value) => {
      handler = value
    }
  }
}
