import { describe, expect, it } from "vitest"

import {
  answersImplementPlan,
  formatElapsed,
  formatTokenCount,
  retryPromptForTurn,
  sessionTurnIsRunning,
  waitingBackgroundTaskLabel
} from "./SessionScreen"

describe("session running state", () => {
  it("includes an optimistic generating turn before the server lifecycle event", () => {
    expect(sessionTurnIsRunning(false, [{ isGenerating: true }])).toBe(true)
    expect(sessionTurnIsRunning(true, [{ isGenerating: false }])).toBe(true)
    expect(sessionTurnIsRunning(false, [{ isGenerating: false }])).toBe(false)
  })
})

describe("manual turn retry", () => {
  it("reuses the user prompt and attachments that own the failed assistant turn", () => {
    const prompt = {
      attachments: [
        {
          fileId: "file-1",
          kind: "file" as const,
          mimeType: "text/plain",
          name: "notes.txt",
          sizeBytes: 12
        }
      ],
      createdAt: "2026-07-13T00:00:00.000Z",
      id: "user-1",
      isGenerating: false,
      role: "user" as const,
      text: "Try this"
    }
    expect(
      retryPromptForTurn(
        [
          prompt,
          {
            createdAt: "2026-07-13T00:00:01.000Z",
            id: "assistant-1",
            isGenerating: false,
            role: "assistant",
            text: ""
          }
        ],
        "assistant-1"
      )
    ).toEqual(prompt)
  })
})

describe("goal banner formatting", () => {
  it("formats token counts like the macOS goal banner", () => {
    expect(formatTokenCount(999)).toBe("999")
    expect(formatTokenCount(1_000)).toBe("1k")
    expect(formatTokenCount(54_000)).toBe("54k")
    expect(formatTokenCount(1_500)).toBe("1.5k")
    expect(formatTokenCount(1_000_000)).toBe("1M")
    expect(formatTokenCount(1_250_000)).toBe("1.3M")
  })

  it("formats elapsed time like the macOS goal banner", () => {
    expect(formatElapsed(59)).toBe("59s")
    expect(formatElapsed(60)).toBe("1m")
    expect(formatElapsed(90 * 60)).toBe("1h 30m")
    expect(formatElapsed(26 * 60 * 60 + 3 * 60)).toBe("1d 2h 3m")
  })
})

describe("plan approval answers", () => {
  it("detects the implement-plan choice by the macOS exit-plan question id", () => {
    expect(
      answersImplementPlan({
        exit_plan_mode: { answers: ["Implement plan"] }
      })
    ).toBe(true)
    expect(
      answersImplementPlan({
        exit_plan_mode: { answers: ["Keep planning"], note: "Refine this first" }
      })
    ).toBe(false)
    expect(answersImplementPlan({ other: { answers: ["Implement plan"] } })).toBe(false)
  })
})

describe("waiting background task indicator", () => {
  it("summarizes background tasks like SessionView.swift", () => {
    expect(waitingBackgroundTaskLabel([{ description: "Running tests" }])).toBe("Running tests")
    expect(
      waitingBackgroundTaskLabel([
        { description: "Running tests" },
        { description: "Checking types" },
        { description: "Building app" }
      ])
    ).toBe("Running tests and 2 more")
  })
})
