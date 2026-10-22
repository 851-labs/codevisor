import { claimBootListener, type BootListener, type BootListenerOptions } from "./boot-listener.js"
import {
  listenCandidates,
  readListenPort,
  recordListenPort,
  resolveListenPortPlan,
  type ListenPortPlan
} from "./infra/listen-port.js"
import { failureMessage } from "./server-http.js"

export interface ServeListenerOptions {
  readonly args: Readonly<Record<string, string | undefined>>
  readonly env: Readonly<Record<string, string | undefined>>
  readonly dataDir: string
  readonly boot: Omit<BootListenerOptions, "candidates">
}

export interface ServeListener {
  readonly listener: BootListener
  readonly plan: ListenPortPlan
}

export const claimServeListener = async (options: ServeListenerOptions): Promise<ServeListener> => {
  const plan = resolveListenPortPlan(options.args, options.env, readListenPort(options.dataDir))
  const listener = await claimBootListener({ ...options.boot, candidates: listenCandidates(plan) })
  const log = options.boot.log ?? console.error

  log(`Codevisor server claimed port ${listener.port}`)
  rememberPort(options, listener.port, log)
  return { listener, plan }
}

const rememberPort = (options: ServeListenerOptions, port: number, log: (line: string) => void) => {
  try {
    recordListenPort(options.dataDir, {
      port,
      pid: options.boot.processId,
      bootId: options.boot.bootId
    })
  } catch (cause) {
    log(`Could not record the listening port: ${failureMessage(cause)}`)
  }
}
