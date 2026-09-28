import {
  CloudApiError,
  removeMachineFromAccount,
  type FetchLike,
  type MachineCredentials
} from "@codevisor/cloud-client"

/// How long logout waits on the cloud before forgetting the machine locally
/// anyway (the caller then tells the user to remove it from the app).
export const ACCOUNT_REMOVAL_TIMEOUT_MS = 5000

/// Asks the cloud to drop this machine from its account with its stored
/// credential (`codevisor auth logout`, app sign-out). True when the machine
/// is off the account — including when nothing is stored or the cloud already
/// rejects the key (removed from an app, or the account is gone); false when
/// the cloud could not be reached or failed.
export const removeMachineFromCloudAccount = async (
  credentials: MachineCredentials | undefined,
  fetchImpl: FetchLike,
  log: (line: string) => void
): Promise<boolean> => {
  if (credentials === undefined) return true
  try {
    await removeMachineFromAccount(
      fetchImpl,
      credentials,
      AbortSignal.timeout(ACCOUNT_REMOVAL_TIMEOUT_MS)
    )
    return true
  } catch (cause) {
    if (cause instanceof CloudApiError && cause.status === 401) return true
    const detail = cause instanceof Error ? cause.message : String(cause)
    log(`Cloud: could not remove this machine from its account: ${detail}`)
    return false
  }
}
