export const UNCAUGHT_EXCEPTION_BUDGET = 20
export const UNCAUGHT_EXCEPTION_WINDOW_MS = 60_000

export interface SafetyNetProcess {
  on(event: "uncaughtException", listener: (error: Error, origin: string) => void): unknown
  on(event: "unhandledRejection", listener: (reason: unknown) => void): unknown
}

export interface SafetyNetOptions {
  log: (line: string) => void
  exit: (code: number) => void
  now: () => number
}

const describe = (reason: unknown): string =>
  reason instanceof Error ? (reason.stack ?? `${reason.name}: ${reason.message}`) : String(reason)

export const installProcessSafetyNet = (
  target: SafetyNetProcess,
  options: SafetyNetOptions
): void => {
  let recent: number[] = []
  target.on("unhandledRejection", (reason) => {
    options.log(`[safety-net] unhandled rejection (server kept running): ${describe(reason)}`)
  })
  target.on("uncaughtException", (error, origin) => {
    const now = options.now()
    recent = [...recent.filter((at) => now - at < UNCAUGHT_EXCEPTION_WINDOW_MS), now]
    if (recent.length > UNCAUGHT_EXCEPTION_BUDGET) {
      options.log(
        `[safety-net] ${recent.length} uncaught exceptions within ${UNCAUGHT_EXCEPTION_WINDOW_MS / 1000}s; exiting: ${describe(error)}`
      )
      options.exit(1)
      return
    }
    options.log(
      `[safety-net] uncaught exception (${origin}; server kept running): ${describe(error)}`
    )
  })
}
