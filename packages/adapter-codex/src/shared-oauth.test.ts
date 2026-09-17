import { describe, expect, it, vi } from "vitest"

import type { CodexClient } from "./client.js"
import { connectSharedCodexAccount } from "./shared-oauth.js"

const fixture = () => {
  let handler!: Parameters<CodexClient["onRequest"]>[0]
  const client: CodexClient = {
    request: vi.fn(async () => ({})) as CodexClient["request"],
    notify: vi.fn(),
    onNotification: vi.fn(),
    onClose: vi.fn(),
    close: vi.fn(),
    onRequest: (value) => {
      handler = value
    }
  }
  const request = (method: string, params: unknown = {}, signal = new AbortController().signal) =>
    handler(method, params, signal)
  return { client, request }
}
describe("Codex external OAuth", () => {
  it("uses externally managed access tokens and retains refresh handling alongside approvals", async () => {
    const f = fixture()
    const token = vi.fn(async (rejected?: string) => ({
      accessToken: rejected ? "new" : "old",
      accountId: "workspace",
      planType: "pro"
    }))
    const client = await connectSharedCodexAccount(f.client, { token })
    expect(f.client.request).toHaveBeenCalledWith("account/login/start", {
      type: "chatgptAuthTokens",
      accessToken: "old",
      chatgptAccountId: "workspace",
      chatgptPlanType: "pro"
    })
    const approval = vi.fn(async () => ({ approved: true }))
    client.onRequest(approval)
    expect(await f.request("approval")).toEqual({ approved: true })
    expect(
      await f.request("account/chatgptAuthTokens/refresh", { previousAccountId: "workspace" })
    ).toEqual({ accessToken: "new", chatgptAccountId: "workspace", chatgptPlanType: "pro" })
    expect(token).toHaveBeenLastCalledWith("old")
    expect(approval).toHaveBeenCalledOnce()
  })
  it("rejects missing identity, mismatched workspace and cancelled requests", async () => {
    const f = fixture()
    await expect(
      connectSharedCodexAccount(f.client, { token: async () => ({ accessToken: "a" }) })
    ).rejects.toThrow("reconnected")
    await connectSharedCodexAccount(f.client, {
      token: async (rejected) => ({ accessToken: "a", accountId: rejected ? "other" : "work" })
    })
    await expect(f.request("unknown")).rejects.toThrow("Unsupported")
    await expect(
      f.request("account/chatgptAuthTokens/refresh", { previousAccountId: "other" })
    ).rejects.toThrow("changed")
    await expect(f.request("account/chatgptAuthTokens/refresh")).rejects.toThrow("changed")
    await expect(
      f.request("account/chatgptAuthTokens/refresh", {}, AbortSignal.abort())
    ).rejects.toThrow()
  })
  it("adopts a remotely refreshed token before the next turn and blocks signed-out accounts", async () => {
    const f = fixture()
    let accessToken = "old",
      signedOut = false
    const client = await connectSharedCodexAccount(f.client, {
      token: async () => {
        if (signedOut) throw new Error("signed out")
        return { accessToken, accountId: "work" }
      }
    })
    await client.request("turn/start", { threadId: "thread" })
    accessToken = "new"
    await client.request("turn/start", { threadId: "thread" })
    expect(f.client.request).toHaveBeenNthCalledWith(3, "account/login/start", {
      type: "chatgptAuthTokens",
      accessToken: "new",
      chatgptAccountId: "work"
    })
    signedOut = true
    await expect(client.request("turn/start", {})).rejects.toThrow("signed out")
    expect(f.client.request).toHaveBeenCalledTimes(4)
  })
})
