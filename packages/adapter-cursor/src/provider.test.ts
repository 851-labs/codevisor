import { harnessCatalog } from "@codevisor/agent-runtime"
import { expect, it } from "vitest"

it("launches Cursor's agent over ACP trusting the workspace, with approvals and its sandbox turned off", () => {
  const definition = harnessCatalog.find((candidate) => candidate.id === "cursor")
  expect(definition?.provider).toBe("cursor")
  expect(definition?.launch).toEqual({
    args: ["--trust", "--force", "--sandbox", "disabled", "acp"],
    command: "cursor-agent",
    kind: "executable"
  })
})
