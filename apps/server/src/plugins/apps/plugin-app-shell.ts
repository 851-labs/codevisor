import { installAppBridge, type BridgeBoot } from "./plugin-app-bridge.js"

export const APP_FRAME_SANDBOX = "allow-scripts allow-forms"

export const appShellHtml = (boot: BridgeBoot): string => {
  const theme = boot.hostContext.theme === "dark" ? "dark" : "light"
  return [
    "<!doctype html>",
    `<html lang="en" style="color-scheme: ${theme}">`,
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>Plugin app</title>",
    `<style>${shellStyle}</style>`,
    "</head>",
    "<body>",
    `<iframe id="app" title="Plugin app" sandbox="${APP_FRAME_SANDBOX}"></iframe>`,
    `<script>${bootScript(boot)}</script>`,
    "</body>",
    "</html>"
  ].join("")
}

export const policyMeta = (policy: string): string =>
  `<meta http-equiv="Content-Security-Policy" content="${escapeAttribute(policy)}">`

export const withPreamble = (html: string, preamble: string): string => {
  const head = /<head\b[^>]*>/i.exec(html)
  if (head !== null) return insertAfter(html, head, preamble)

  const doctype = /^\s*<!doctype[^>]*>/i.exec(html)
  if (doctype !== null) return insertAfter(html, doctype, preamble)
  return `${preamble}${html}`
}

export const scriptJson = (value: unknown): string =>
  JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(" ", "\\u2028")
    .replaceAll(" ", "\\u2029")

const shellStyle =
  "html,body{margin:0;padding:0;background:transparent}iframe{display:block;border:0;width:100%;height:100vh}"

const bootScript = (boot: BridgeBoot): string =>
  [
    `const boot = ${scriptJson(boot)};`,
    'const frame = document.getElementById("app");',
    "const native = window.webkit?.messageHandlers?.codevisorApp;",
    "const host = {",
    'listen: (handler) => window.addEventListener("message", handler),',
    "fetch: (url, init) => window.fetch(url, init),",
    "post: (message) => { if (native === undefined) return false; native.postMessage(message); return true },",
    'open: (url) => { window.open(url, "_blank", "noopener") },',
    "hasUserActivation: () => window.navigator?.userActivation?.isActive === true",
    "};",
    `window.codevisorHost = (${installAppBridge.toString()})({ boot, frame, host, pathname: window.location.pathname });`
  ].join("\n")

const insertAfter = (html: string, match: RegExpExecArray, text: string): string => {
  const end = match.index + match[0].length
  return `${html.slice(0, end)}${text}${html.slice(end)}`
}

const escapeAttribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")
