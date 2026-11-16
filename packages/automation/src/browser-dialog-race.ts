import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { tabSessionOf } from "./browser-frame-sessions.js"

export type DialogRace<T> =
  | { readonly dialogOpened: false; readonly result: T }
  | { readonly dialogOpened: true; readonly completion: Promise<T | undefined> }

export const sendUnlessDialogOpens = async <T = Readonly<Record<string, unknown>>>(
  runtime: BrowserRuntime,
  page: PageHandle,
  method: string,
  params: Readonly<Record<string, unknown>>
): Promise<DialogRace<T>> => {
  const { promise: dialog, resolve: resolveDialog } = Promise.withResolvers<void>()
  const stop = runtime.connection.on(
    "Page.javascriptDialogOpening",
    () => resolveDialog(),
    tabSessionOf(runtime, page.sessionId)
  )
  const command = runtime.connection.send<T>(method, params, page.sessionId)
  try {
    const outcome = await Promise.race([
      command.then((result) => ({ dialogOpened: false as const, result })),
      dialog.then(() => "dialog" as const)
    ])
    if (outcome !== "dialog") return outcome
    return { dialogOpened: true, completion: command.catch(() => undefined) }
  } finally {
    stop()
  }
}
