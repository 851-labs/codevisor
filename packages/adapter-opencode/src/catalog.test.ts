import { describe, expect, it, vi } from "vitest"

import {
  configOptions,
  loadCatalog,
  permissionsGated,
  resolveChange,
  sessionModes,
  type Catalog
} from "./catalog.js"
import { makeFakeServer, type RecordedRequest } from "./test-support.js"

const catalogResponses =
  (overrides: Partial<Record<string, unknown>> = {}) =>
  (request: RecordedRequest): unknown => {
    const responses: Record<string, unknown> = {
      "/api/plugin": { data: [{ id: "core" }] },
      "/api/model": {
        data: [
          {
            id: "m1",
            providerID: "openrouter",
            name: "M1",
            variants: [{ id: "default" }, { id: "high" }],
            limit: { context: 500 }
          },
          { id: "off", providerID: "openrouter", enabled: false },
          { id: "m0", providerID: "anthropic", name: "M0" },
          { providerID: "broken" }
        ]
      },
      "/api/model/default": { data: { providerID: "openrouter", id: "m1" } },
      "/api/agent": {
        data: [
          { id: "build", name: "Build", mode: "primary" },
          { id: "general", mode: "subagent" },
          { id: "title", mode: "primary", hidden: true },
          { id: "plan", name: "Plan", description: "Read-only planning" }
        ]
      },
      "/api/command": { data: [{ name: "review" }, { nope: true }] },
      "/api/skill": {
        data: [
          { id: "opencode", description: "About OpenCode", path: "/builtin/opencode.md" },
          { id: "lint", path: "/work/.opencode/skills/lint/SKILL.md" },
          { id: "notes", path: "/home/me/.claude/skills/notes/SKILL.md" },
          { id: "computer-use", path: "/home/me/skills/computer-use/SKILL.md" },
          { id: "bare" }
        ]
      },
      ...overrides
    }
    return responses[request.path]
  }

describe("OpenCode catalog", () => {
  it("loads models, modes, commands and skills for a project", async () => {
    const fake = makeFakeServer(catalogResponses())
    const catalog = await loadCatalog(fake.server, "/work", async () => undefined)
    expect(fake.requests.every((request) => request.location === "/work")).toBe(true)
    expect(catalog).toEqual({
      models: [
        {
          providerID: "openrouter",
          id: "m1",
          name: "M1",
          variants: ["default", "high"],
          context: 500
        },
        { providerID: "anthropic", id: "m0", name: "M0", variants: [] }
      ],
      defaultModel: { providerID: "openrouter", id: "m1", variant: "default" },
      modes: [
        { id: "build", name: "Build" },
        { id: "plan", name: "Plan", description: "Read-only planning" }
      ],
      defaultModeID: "build",
      commands: ["review"],
      skills: {
        invocationPrefix: "/",
        skills: [
          {
            name: "opencode",
            invocation: "/opencode",
            description: "About OpenCode",
            source: "builtin"
          },
          { name: "lint", invocation: "/lint", source: "project" },
          { name: "notes", invocation: "/notes", source: "user" },
          { name: "bare", invocation: "/bare" }
        ]
      }
    })
  })

  it("waits for plugins and a usable model before giving up", async () => {
    let plugins = 0
    const responses = catalogResponses({ "/api/skill": undefined })
    const wait = vi.fn(async () => undefined)
    const fake = makeFakeServer((request) =>
      request.path === "/api/plugin"
        ? { data: ++plugins < 3 ? [] : [{ id: "core" }] }
        : responses(request)
    )
    await expect(loadCatalog(fake.server, "/work", wait)).resolves.toMatchObject({
      skills: { skills: [] }
    })
    expect(wait).toHaveBeenCalledTimes(2)

    const empty = makeFakeServer(catalogResponses({ "/api/model": { data: [] } }))
    await expect(loadCatalog(empty.server, "/work", async () => undefined)).rejects.toThrow(
      "OpenCode has no models or agents available for this project."
    )
    const late = makeFakeServer((request) =>
      request.path === "/api/plugin" ? { data: [] } : catalogResponses()(request)
    )
    await expect(loadCatalog(late.server, "/work", async () => undefined)).resolves.toMatchObject({
      defaultModeID: "build"
    })
  })

  const catalog: Catalog = {
    models: [
      { providerID: "openrouter", id: "m1", name: "M1", variants: ["low", "high"] },
      { providerID: "anthropic", id: "m0", name: "M0", variants: [] }
    ],
    defaultModel: { providerID: "openrouter", id: "m1" },
    modes: [
      { id: "build", name: "Build" },
      { id: "architect", name: "Read-only" }
    ],
    defaultModeID: "build",
    commands: [],
    skills: { invocationPrefix: "/", skills: [] }
  }

  it("advertises model and effort options with the current selection", () => {
    expect(
      configOptions(catalog, { model: { providerID: "openrouter", id: "m1", variant: "medium" } })
    ).toEqual([
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "openrouter/m1",
        options: [
          { value: "anthropic/m0", name: "anthropic/M0" },
          { value: "openrouter/m1", name: "openrouter/M1" }
        ]
      },
      {
        id: "effort",
        name: "Effort",
        description: "Available effort levels for this model",
        category: "thought_level",
        currentValue: "low",
        options: [
          { value: "low", name: "Low" },
          { value: "high", name: "High" },
          { value: "default", name: "Default" }
        ]
      }
    ])
    expect(
      configOptions(catalog, { model: { providerID: "anthropic", id: "m0" } }).map(
        (option) => option.id
      )
    ).toEqual(["model"])
  })

  it("reports OpenCode's agents as session modes the composer can pick", () => {
    const withPlan: Catalog = {
      ...catalog,
      modes: [...catalog.modes, { id: "plan", name: "Plan", description: "Plan before editing" }]
    }
    expect(sessionModes(withPlan, {})).toEqual({
      currentModeId: "build",
      availableModes: [
        { id: "build", name: "Build" },
        { id: "architect", name: "Read-only", canonicalId: "readOnly" },
        { id: "plan", name: "Plan", description: "Plan before editing", canonicalId: "plan" }
      ]
    })
    expect(sessionModes(withPlan, { agent: "plan" }).currentModeId).toBe("plan")
  })

  it("resolves selections, keeping a compatible effort when the model stays the same", () => {
    const selection = { model: { providerID: "openrouter", id: "m1", variant: "high" } }
    expect(resolveChange(catalog, selection, "model", "openrouter/m1")).toEqual({
      model: selection.model
    })
    expect(resolveChange(catalog, selection, "model", "anthropic/m0")).toEqual({
      model: { providerID: "anthropic", id: "m0" }
    })
    expect(resolveChange(catalog, {}, "model", "openrouter/m1/low")).toEqual({
      model: { providerID: "openrouter", id: "m1", variant: "low" }
    })
    expect(resolveChange(catalog, {}, "effort", "default")).toEqual({
      model: { providerID: "openrouter", id: "m1", variant: "default" }
    })
    expect(resolveChange(catalog, {}, "mode", "architect")).toEqual({ agent: "architect" })
    expect(() => resolveChange(catalog, {}, "model", "nope/nothing")).toThrow(
      "Unknown OpenCode model"
    )
    expect(() => resolveChange(catalog, {}, "mode", "nope")).toThrow("Unknown OpenCode mode")
    expect(() => resolveChange(catalog, {}, "speed", "fast")).toThrow(
      "Unknown OpenCode config option"
    )
  })

  it("gates permissions in planning and read-only modes", () => {
    expect(permissionsGated(catalog, {})).toBe(false)
    expect(permissionsGated(catalog, { agent: "architect" })).toBe(true)
    expect(permissionsGated(catalog, { agent: "plan" })).toBe(true)
  })
})
