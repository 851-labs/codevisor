import { describe, expect, it } from "vitest"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"

describe("parseDevelopmentRunnerArguments", () => {
  it("uses containers by default", () => {
    expect(parseDevelopmentRunnerArguments([])).toEqual({
      containerEnginePreference: undefined,
      wantsContainers: true
    })
    expect(parseDevelopmentRunnerArguments(["--containers"]).wantsContainers).toBe(true)
  })

  it("shares the container opt-out and engine flags across runners", () => {
    expect(parseDevelopmentRunnerArguments(["--no-containers"]).wantsContainers).toBe(false)
    expect(parseDevelopmentRunnerArguments(["--container-engine=docker"])).toEqual({
      containerEnginePreference: "docker",
      wantsContainers: true
    })
    expect(parseDevelopmentRunnerArguments(["--container-engine=none"])).toEqual({
      containerEnginePreference: "none",
      wantsContainers: false
    })
    expect(() => parseDevelopmentRunnerArguments(["--container-engine=bogus"])).toThrow(
      /Unknown container engine: bogus/
    )
  })

  it("lets a runner add private flags without widening the public surface", () => {
    expect(
      parseDevelopmentRunnerArguments(["--no-ios"], { allowedArguments: ["--no-ios"] })
        .wantsContainers
    ).toBe(true)
    expect(() => parseDevelopmentRunnerArguments(["--no-ios"])).toThrow(
      /Unknown development runner argument: --no-ios/
    )
    expect(() => parseDevelopmentRunnerArguments(["--surprise"])).toThrow(
      /Unknown development runner argument: --surprise/
    )
  })
})
