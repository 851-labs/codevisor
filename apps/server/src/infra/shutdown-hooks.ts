export const SHUTDOWN_HOOK_LIMIT_MS = 500

export interface ShutdownHooks {
  readonly add: (hook: () => Promise<void>) => void
  readonly exit: (code: number) => Promise<void>
}

const waitFor = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms).unref()
  })

export const makeShutdownHooks = (options: {
  readonly exit: (code: number) => void
  readonly limitMs?: number
  readonly wait?: (ms: number) => Promise<void>
}): ShutdownHooks => {
  const hooks: Array<() => Promise<void>> = []
  let exiting: Promise<void> | undefined
  const wait = options.wait ?? waitFor
  return {
    add: (hook) => {
      hooks.push(hook)
    },
    exit: (code) => {
      exiting ??= (async () => {
        const settled = Promise.allSettled(hooks.map(async (hook) => hook()))
        await Promise.race([settled, wait(options.limitMs ?? SHUTDOWN_HOOK_LIMIT_MS)])
        options.exit(code)
      })()
      return exiting
    }
  }
}

export const processShutdown = makeShutdownHooks({ exit: (code) => process.exit(code) })
