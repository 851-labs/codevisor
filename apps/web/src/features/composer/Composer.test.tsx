import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it } from "vitest"

import { Composer, isTypeToFocusKey } from "./Composer"

describe("composer cancellation state", () => {
  it("replaces the stop action with a stopping indicator", () => {
    const markup = renderToStaticMarkup(
      <Composer
        value=""
        onValueChange={() => undefined}
        isSending
        isCancelling
        onStop={() => undefined}
        onSend={() => undefined}
      />
    )

    expect(markup).toContain('role="status"')
    expect(markup).toContain('aria-label="Stopping"')
    expect(markup).not.toContain('aria-label="Stop"')
  })
})

describe("composer type-to-focus keys", () => {
  const keyEvent = (overrides: Partial<Parameters<typeof isTypeToFocusKey>[0]> = {}) => ({
    key: "a",
    ctrlKey: false,
    metaKey: false,
    altKey: false,
    isComposing: false,
    defaultPrevented: false,
    ...overrides
  })

  it("accepts unmodified printable characters", () => {
    expect(isTypeToFocusKey(keyEvent())).toBe(true)
    expect(isTypeToFocusKey(keyEvent({ key: " " }))).toBe(true)
    expect(isTypeToFocusKey(keyEvent({ key: "A" }))).toBe(true)
  })

  it("ignores shortcuts, composition, handled events, and control keys", () => {
    expect(isTypeToFocusKey(keyEvent({ metaKey: true }))).toBe(false)
    expect(isTypeToFocusKey(keyEvent({ ctrlKey: true }))).toBe(false)
    expect(isTypeToFocusKey(keyEvent({ altKey: true }))).toBe(false)
    expect(isTypeToFocusKey(keyEvent({ isComposing: true }))).toBe(false)
    expect(isTypeToFocusKey(keyEvent({ defaultPrevented: true }))).toBe(false)
    expect(isTypeToFocusKey(keyEvent({ key: "Enter" }))).toBe(false)
  })
})
