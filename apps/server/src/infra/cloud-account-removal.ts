import {
  CloudApiError,
  removeMachineFromAccount,
  type FetchLike,
  type MachineCredentials
} from "@codevisor/cloud-client"

export const ACCOUNT_REMOVAL_TIMEOUT_MS = 5000

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
