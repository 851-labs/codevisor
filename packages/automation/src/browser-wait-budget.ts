export const defaultWaitMs = 30_000
export const maxWaitMs = 120_000

export const waitBudget = (requested: unknown, fallback = defaultWaitMs): number => {
  if (requested === undefined || requested === null) return fallback

  const ms = Number(requested)
  if (!Number.isFinite(ms) || ms < 0) throw new Error("timeoutMs must be 0 or more milliseconds")
  if (ms > maxWaitMs) {
    throw new Error(
      `timeoutMs can be at most ${maxWaitMs} (2 minutes), and ${ms} was asked for. Wait on a condition, or wait again.`
    )
  }
  return ms
}
