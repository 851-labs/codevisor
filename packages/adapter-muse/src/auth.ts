import type { HarnessAuthInspection } from "@codevisor/agent-runtime"

import type { MuseClient } from "./client.js"
import { record, text, type AccountState } from "./protocol.js"

const SIGNED_IN = new Set(["accountLogin", "apiKey", "envKey"])

export const accountInspection = (account: AccountState): HarnessAuthInspection => {
  if (SIGNED_IN.has(account.state))
    return {
      state: "authenticated",
      methods: [],
      canLogout: account.state !== "envKey",
      ...(account.label === undefined ? {} : { label: account.label })
    }
  if (account.state === "loggedOut" && !account.credentialRequired)
    return { state: "notRequired", methods: [], canLogout: false }
  return {
    state: "unauthenticated",
    methods: [],
    canLogout: false,
    detail: "Sign in to Muse Code with your Meta account or a Meta API key."
  }
}

export const readMuseAccount = async (client: MuseClient): Promise<AccountState> => {
  const account = record(await client.request("account/read", {}))
  const label = text(account.label)
  return {
    state: text(account.state) ?? "loggedOut",
    credentialRequired: account.credentialRequired !== false,
    ...(label === undefined ? {} : { label })
  }
}

export interface MuseLogin {
  readonly verificationUrl?: string
  readonly userCode?: string
  readonly completed: Promise<{ readonly outcome: string; readonly message?: string }>
}

export const startMuseLogin = async (
  client: MuseClient,
  login: { readonly type: "deviceCode" } | { readonly type: "apiKey"; readonly apiKey: string }
): Promise<MuseLogin> => {
  const completed = new Promise<{ outcome: string; message?: string }>((resolve) => {
    client.onNotification((method, params) => {
      if (method !== "account/loginCompleted") return
      const event = record(params)
      const message = text(event.message)
      resolve({
        outcome: text(event.outcome) ?? "failed",
        ...(message === undefined ? {} : { message })
      })
    })
    client.onClose((error) => resolve({ outcome: "failed", message: error.message }))
  })
  const started = record(await client.request("account/loginStart", login))
  if (login.type === "apiKey") return { completed: Promise.resolve({ outcome: "granted" }) }
  const verificationUrl = text(started.verificationUrl)
  const userCode = text(started.userCode)
  return {
    ...(verificationUrl === undefined ? {} : { verificationUrl }),
    ...(userCode === undefined ? {} : { userCode }),
    completed
  }
}

export const cancelMuseLogin = (client: MuseClient): Promise<unknown> =>
  client.request("account/loginCancel", {})

export const logoutMuse = (client: MuseClient): Promise<unknown> =>
  client.request("account/logout", {})
