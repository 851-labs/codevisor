import { openDialog, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"

const worksWhileDialogOpen = new Set([
  "dialog",
  "getJsDialog",
  "tab_info",
  "dev.logs",
  "cdp.send",
  "cdp.readEvents",
  "playwright.waitForTimeout",
  "playwright.waitForEvent"
])

export const requireNoOpenDialog = (
  runtime: BrowserRuntime,
  page: PageHandle,
  toolName: string
): void => {
  const dialog = openDialog(runtime, page)
  if (dialog === undefined || worksWhileDialogOpen.has(toolName)) return

  throw new Error(openDialogMessage(dialog))
}

export const awaitsDialogAnswer = (runtime: BrowserRuntime, targetId: string): boolean => {
  const sessionId = runtime.sessions.get(targetId)
  return sessionId !== undefined && runtime.dialogs.has(sessionId)
}

const openDialogMessage = (dialog: Readonly<Record<string, unknown>>): string => {
  const said = typeof dialog.message === "string" && dialog.message !== "" ? dialog.message : ""
  const quoted = said === "" ? "" : ` saying ${JSON.stringify(said.slice(0, 200))}`
  return `${dialogName(dialog.type)} is open on this tab${quoted}, so the page can't respond until it is answered. Read it with tab.getJsDialog(), then call accept() or dismiss() on it.`
}

const dialogName = (type: unknown): string => {
  if (type === "beforeunload") return "A leave-page dialog"
  if (type === "confirm" || type === "prompt") return `A JavaScript ${type}`
  return "A JavaScript alert"
}
