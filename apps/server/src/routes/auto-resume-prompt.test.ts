import { describe, expect, it } from "vitest"

import { autoResumePrompt } from "./auto-resume-prompt.js"

const session = { id: "chat-1", title: 'Fix "login" & <signup>' }

describe("auto-resume prompt", () => {
  it("asks the agent to continue and reminds it of the user's last message", () => {
    expect(autoResumePrompt(session, "  Add a remember-me checkbox  ")).toBe(
      [
        '<codevisor-event type="session.usage_limit_reset" sessionId="chat-1" title="Fix &quot;login&quot; &amp; &lt;signup>">',
        "The usage limit that stopped your last turn has reset. Continue the interrupted work from where you left off. Don't start over or repeat steps you already finished.",
        "",
        "The user's last message, for reference:",
        "Add a remember-me checkbox",
        "</codevisor-event>"
      ].join("\n")
    )
  })

  it("leaves the reminder out when there is no message and bounds a long one", () => {
    expect(autoResumePrompt(session, undefined)).not.toContain("last message")
    expect(autoResumePrompt(session, " ")).not.toContain("last message")

    const long = autoResumePrompt(session, "x".repeat(2_500))

    expect(long).toContain(`${"x".repeat(2_000)}\n…(truncated)\n</codevisor-event>`)
    expect(long).not.toContain("x".repeat(2_001))
  })
})
