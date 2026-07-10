import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it } from "vitest"

import { Composer } from "./Composer"

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
