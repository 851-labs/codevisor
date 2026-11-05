import { afterEach, describe, expect, it, vi } from "vitest"

const loadCatalog = async (devInstanceId: string | undefined) => {
  vi.resetModules()
  vi.stubEnv("CODEVISOR_DEV_INSTANCE_ID", devInstanceId)
  return (await import("./harness-catalog.js")).harnessCatalog
}

afterEach(() => {
  vi.unstubAllEnvs()
})

describe("development test harness", () => {
  it("is listed only for development instances, with nothing to install or update", async () => {
    expect(
      (await loadCatalog(undefined)).some((harness) => harness.id === "codevisor-test-agent")
    ).toBe(false)

    const testAgent = (await loadCatalog("worktree-1234")).find(
      (harness) => harness.id === "codevisor-test-agent"
    )
    expect(testAgent).toMatchObject({
      detectBinaries: ["codevisor-test-agent"],
      launch: { kind: "executable", command: "codevisor-test-agent", args: ["acp"] }
    })
    expect(testAgent?.installMethods ?? []).toEqual([])
    expect(testAgent?.update).toBeUndefined()
  })
})
