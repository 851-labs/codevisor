import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { evaluatedValue } from "./browser-cdp.js"
import { tabSessionIds } from "./browser-frame-sessions.js"
import { optionalString, recordOrEmpty } from "./unknown-values.js"

interface FrameNode {
  readonly frame: { readonly id: string }
  readonly childFrames?: ReadonlyArray<FrameNode>
}

interface FrameText {
  readonly title: string
  readonly url: string
  readonly text: string
}

const frameTextExpression =
  "({ title: document.title, url: location.href, text: document.body ? document.body.innerText : '' })"

export const frameMarkdownSections = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<string> => {
  const sessions = tabSessionIds(runtime, page.sessionId)
  const texts = await Promise.all(
    sessions.map((sessionId) => sessionFrameTexts(runtime, sessionId, sessionId === page.sessionId))
  )
  return texts
    .flat()
    .filter((frame) => frame.text.trim() !== "")
    .map(
      (frame) =>
        `\n\n## Frame: ${frame.title || frame.url}\n\nSource: ${frame.url}\n\n${frame.text}`
    )
    .join("")
}

const sessionFrameTexts = async (
  runtime: BrowserRuntime,
  sessionId: string,
  isPage: boolean
): Promise<FrameText[]> => {
  const { frameTree } = await runtime.connection.send<{ frameTree: FrameNode }>(
    "Page.getFrameTree",
    {},
    sessionId
  )
  const frames = isPage ? descendants(frameTree) : [frameTree, ...descendants(frameTree)]
  const texts = await Promise.all(
    frames.map((frame) => frameText(runtime, sessionId, frame.frame.id).catch(() => undefined))
  )
  return texts.flatMap((text) => (text === undefined ? [] : [text]))
}

const descendants = (node: FrameNode): FrameNode[] =>
  (node.childFrames ?? []).flatMap((child) => [child, ...descendants(child)])

const frameText = async (
  runtime: BrowserRuntime,
  sessionId: string,
  frameId: string
): Promise<FrameText> => {
  const world = await runtime.connection.send<{ executionContextId: number }>(
    "Page.createIsolatedWorld",
    { frameId, worldName: "codevisor-export" },
    sessionId
  )
  const value = recordOrEmpty(
    evaluatedValue(
      await runtime.connection.send(
        "Runtime.evaluate",
        {
          expression: frameTextExpression,
          contextId: world.executionContextId,
          returnByValue: true
        },
        sessionId
      )
    )
  )
  return {
    title: optionalString(value.title) ?? "",
    url: optionalString(value.url) ?? "",
    text: optionalString(value.text) ?? ""
  }
}
