import { harnessCatalog } from "@codevisor/agent-runtime"
import { expect, it } from "vitest"

it("launches Cursor's agent over ACP with approvals and its sandbox turned off, trusting the workspace when its CLI supports --trust", () => {
  const definition = harnessCatalog.find((candidate) => candidate.id === "cursor")
  expect(definition?.provider).toBe("cursor")
  expect(definition?.launch).toEqual({
    args: ["--force", "--sandbox", "disabled", "acp"],
    command: "cursor-agent",
    kind: "executable",
    trustFlag: { args: ["--trust"], probe: ["--help"], probeMentions: "--trust" }
  })
})
