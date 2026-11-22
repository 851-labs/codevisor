import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import {
  installServerDiagnostics,
  type DiagnosticReport
} from "../infra/diagnostics/server-diagnostics.js"
import { HarnessTurnError, reportTurnFailure, turnFailureOf } from "./turn-failure-reports.js"

const captured: Array<{ cause: unknown; report: DiagnosticReport }> = []

const install = () =>
  installServerDiagnostics({
    capture: async (cause, report) => {
      captured.push({ cause, report })
    }
  })

const db = { getSessionSummary: () => Effect.succeed({ harnessId: "codex" }) }

afterEach(() => {
  installServerDiagnostics(undefined)
  captured.length = 0
})

describe("turn failure reports", () => {
  it("recognizes harness errors and turns that ended in a harness failure", () => {
    const error = turnFailureOf({
      kind: "session.error",
      subjectId: "s",
      payload: { message: "rate limited 429" }
    })
    expect(error?.cause).toBeInstanceOf(HarnessTurnError)
    expect(error?.stopKind).toBe("harnessFailed")

    const ended = turnFailureOf({
      kind: "session.updated",
      subjectId: "s",
      payload: { turnState: "ended", stopKind: "harnessFailed", stopDetail: "process exited 1" }
    })
    expect(ended?.cause).toMatchObject({ message: "process exited 1" })

    expect(
      turnFailureOf({ kind: "session.updated", subjectId: "s", payload: { turnState: "ended" } })
    ).toBeUndefined()
  })

  it("reports harness failures grouped by message and skips sign-in stops", async () => {
    install()
    await reportTurnFailure(db, "s", {
      cause: new HarnessTurnError("timed out after 30s"),
      stopKind: "harnessFailed"
    })
    await reportTurnFailure(db, "s", {
      cause: new Error("not logged in"),
      stopKind: "authRequired"
    })

    expect(captured.map(({ report }) => report)).toEqual([
      {
        component: "turn",
        groupBy: "timed out after #s",
        tags: { stop_kind: "harnessFailed", harness_id: "codex" }
      }
    ])
  })
})
