import {
  SharedCredentialError,
  type SharedCredentialReference,
  type SharedCredentialVault,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

import type { SharedHarnessAccount } from "./shared-account-store.js"

export const machineLoginReplacesDeadGrant = async (
  vault: SharedCredentialVault,
  bundle: SharedTokenBundle,
  previous: SharedHarnessAccount | undefined
): Promise<boolean> => {
  if (!isLiveMachineLogin(bundle)) return false
  if (previous?.credential === undefined || previous.sourceMachineId !== undefined) return false

  return needsSignIn(vault, previous.credential)
}

const liveLoginMarginMs = 60_000

const isLiveMachineLogin = (bundle: SharedTokenBundle): boolean =>
  bundle.ownership === "external" && bundle.expiresAt > Date.now() + liveLoginMarginMs

const needsSignIn = async (
  vault: SharedCredentialVault,
  credential: SharedCredentialReference
): Promise<boolean> => {
  try {
    await vault.token(credential)
    return false
  } catch (cause) {
    return cause instanceof SharedCredentialError && cause.reason === "reauthenticate"
  }
}
