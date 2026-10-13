import type { HarnessAuthInspection } from "@codevisor/agent-runtime"

import type { MuseClient } from "./client.js"
import { record, text, type AccountState } from "./protocol.js"

/// Muse Code sign-in over MSP's (experimental) account surface: the same
/// state and device-code flow `muse login` uses, without a terminal.

const SIGNED_IN = new Set(["accountLogin", "apiKey", "envKey"])

export const accountInspection = (account: AccountState): HarnessAuthInspection => {
  if (SIGNED_IN.has(account.state))
    return {
      state: "authenticated",
      methods: [],
      // A key from the environment isn't Muse's to remove.
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
  return {
    state: text(account.state) ?? "loggedOut",
    credentialRequired: account.credentialRequired !== false,
    ...(text(account.label) === undefined ? {} : { label: account.label as string })
  }
}

export interface MuseLogin {
  /// Where to sign in, for the device-code flow; absent for an API key,
  /// which Muse stores before answering.
  readonly verificationUrl?: string
  readonly userCode?: string
  /// Settles with Muse's verdict: `granted`, `denied`, `expired`, …
  readonly completed: Promise<{ readonly outcome: string; readonly message?: string }>
}

/// Starts a sign-in on a host dedicated to it: the device-code flow lives
/// as long as that host does, so the caller keeps it open until `completed`.
export const startMuseLogin = async (
  client: MuseClient,
  login: { readonly type: "deviceCode" } | { readonly type: "apiKey"; readonly apiKey: string }
): Promise<MuseLogin> => {
  const completed = new Promise<{ outcome: string; message?: string }>((resolve) => {
    client.onNotification((method, params) => {
      if (method !== "account/loginCompleted") return
      const event = record(params)
      resolve({
        outcome: text(event.outcome) ?? "failed",
        ...(text(event.message) === undefined ? {} : { message: event.message as string })
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
