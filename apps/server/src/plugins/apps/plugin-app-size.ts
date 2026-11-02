export const CONTENT_SIZE_METHOD = "codevisor/notifications/content-size"

export interface ContentSizeEnv {
  readonly measure: () => number
  readonly observe: (changed: () => void) => void
  readonly post: (height: number) => void
}

export const contentSizeScript = (): string =>
  [
    "<script>",
    `(${installContentSizeReporter.toString()})({`,
    `measure: ${measureContentHeight},`,
    `observe: ${observeContentResizes},`,
    `post: (height) => window.parent.postMessage({ jsonrpc: "2.0", method: "${CONTENT_SIZE_METHOD}", params: { height } }, "*")`,
    "});",
    "</script>"
  ].join("\n")

export const installContentSizeReporter = (env: ContentSizeEnv): void => {
  let reported: number | undefined

  env.observe(() => {
    const height = env.measure()
    if (height === reported) return

    reported = height
    env.post(height)
  })
}

const measureContentHeight = `() => {
  const root = document.documentElement
  const height = root.style.height
  root.style.height = "max-content"
  const measured = Math.ceil(root.getBoundingClientRect().height)
  root.style.height = height
  return measured
}`

const observeContentResizes = `(changed) => {
  const observer = new ResizeObserver(() => requestAnimationFrame(changed))
  observer.observe(document.documentElement)
  document.addEventListener("DOMContentLoaded", () => observer.observe(document.body))
}`
