/// Last line of defence for the server process. It hosts every running agent,
/// so Node's default — exit on any uncaught exception or unhandled rejection —
/// turns one stray throw on one connection (a send on a closing socket, an
/// 'error' event nobody listened for) into every chat on the machine stopping
/// mid-turn. The bugs themselves are fixed where they occur; this keeps the
/// next one from costing more than its own connection, and makes it visible
/// in server.log instead of a silent restart.
///
/// Unhandled rejections are logged and otherwise ignored: the promise is
/// already settled, nothing else is torn down. Uncaught exceptions are logged
/// and survived too, but a burst of them means something is spinning in a
/// broken state, so past a budget the process exits and the app restarts it.

/// Uncaught exceptions tolerated inside one window before exiting.
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
