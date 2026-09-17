import type { HarnessAccountContext } from "@codevisor/agent-runtime"

import type { CodexClient } from "./client.js"

/// External-token mode keeps refresh ownership in Codevisor. Wrapping the
/// request handler preserves it when the session installs approval handlers.
export const connectSharedCodexAccount = async (
  client: CodexClient,
  oauth: NonNullable<HarnessAccountContext["oauth"]>
): Promise<CodexClient> => {
  let current = await oauth.token()
  if (!current.accountId) throw new Error("This ChatGPT account needs to be reconnected")
  let handler: Parameters<CodexClient["onRequest"]>[0] | undefined
  client.onRequest(async (method, params, signal) => {
    if (method !== "account/chatgptAuthTokens/refresh") {
      if (!handler) throw new Error("Unsupported Codex request")
      return handler(method, params, signal)
    }
    signal.throwIfAborted()
    const previous = params as { previousAccountId?: string }
    if (previous?.previousAccountId && previous.previousAccountId !== current.accountId)
      throw new Error("ChatGPT account changed; reconnect this chat")
    const next = await oauth.token(current.accessToken)
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
    onRequest: (value) => {
      handler = value
    }
  }
}
