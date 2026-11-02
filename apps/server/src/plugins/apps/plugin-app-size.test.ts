import { runInNewContext } from "node:vm"

import { describe, expect, it } from "vitest"

import {
  CONTENT_SIZE_METHOD,
  contentSizeScript,
  installContentSizeReporter
} from "./plugin-app-size.js"

const fakePage = (heights: ReadonlyArray<number>) => {
  const observed: Array<unknown> = []
  const posted: Array<unknown> = []
  const styles: Array<string> = []
  const root = {
    style: { height: "100%" },
    getBoundingClientRect: () => {
      styles.push(root.style.height)
      return { height: heights[Math.min(styles.length - 1, heights.length - 1)]! }
    }
  }
  const body = {}
  let resized: (() => void) | undefined
  let loaded: (() => void) | undefined
  const context = {
    window: { parent: { postMessage: (message: unknown) => posted.push(message) } },
    document: {
      documentElement: root,
      body,
      addEventListener: (_type: string, listener: () => void) => {
        loaded = listener
      }
    },
    ResizeObserver: class {
      constructor(callback: () => void) {
        resized = callback
      }
      observe(target: unknown) {
        observed.push(target)
      }
    },
    requestAnimationFrame: (callback: () => void) => callback()
  }
  runInNewContext(contentSizeScript().replace(/^<script>|<\/script>$/g, ""), context)
  return {
    body,
    loaded: () => loaded?.(),
    observed,
    posted,
    resize: () => resized?.(),
    root,
    styles
  }
}

describe("plugin app content size", () => {
  it("reports the content height each time it changes", () => {
    const posted: Array<number> = []
    let changed: (() => void) | undefined
    const heights = [320, 320, 410]
    installContentSizeReporter({
      measure: () => heights.shift()!,
      observe: (callback) => {
        changed = callback
      },
      post: (height) => posted.push(height)
    })

    for (const _ of [1, 2, 3]) changed?.()

    expect(posted).toEqual([320, 410])
  })

  it("measures the page's content rather than its viewport and posts it to the host", () => {
    const page = fakePage([512.2, 640])

    page.loaded()
    page.resize()
    page.resize()

    expect(page.observed).toEqual([page.root, page.body])
    expect(page.styles).toEqual(["max-content", "max-content"])
    expect(page.root.style.height).toBe("100%")
    expect(page.posted).toEqual([
      { jsonrpc: "2.0", method: CONTENT_SIZE_METHOD, params: { height: 513 } },
      { jsonrpc: "2.0", method: CONTENT_SIZE_METHOD, params: { height: 640 } }
    ])
  })
})
