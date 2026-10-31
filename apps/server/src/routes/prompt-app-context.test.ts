import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  APP_CONTEXT_MAX_CHARS,
  markAppContextsDelivered,
  withAppContexts
} from "./prompt-app-context.js"

const sessionWithContexts = async (contexts: ReadonlyArray<Record<string, unknown>>) => {
  const { services } = await makeServices()
  const project = await run(services.db.createProject({ folderPath: "/tmp/prompt-app-context" }))
  const session = await run(
    services.db.createSession({ harnessId: "codex", projectId: project.id })
  )
  for (const [index, context] of contexts.entries()) {
    await run(
      services.db.savePluginAppContext({
        sessionId: session.id,
        viewId: `view-${index}`,
        plugin: 'Zillow "Homes"',
        tool: "zillow_property_search",
        context
      })
    )
  }
  return { services, sessionId: session.id }
}

describe("app context in prompts", () => {
  it("leaves out empty contexts and caps long ones, but consumes them all", async () => {
    const long = "x".repeat(APP_CONTEXT_MAX_CHARS + 10)
    const { services, sessionId } = await sessionWithContexts([
      { content: [{ type: "image", data: "..." }, "loose", null] },
      { content: [{ type: "text", text: long }] },
      { content: "not a list" }
    ])

    const prompt = await withAppContexts(services, sessionId, "Show me cheaper ones")
    await markAppContextsDelivered(services, sessionId, prompt.delivered)

    expect(prompt.text).toBe(
      `<codevisor-app-context plugin="Zillow &quot;Homes&quot;" tool="zillow_property_search" viewId="view-1">\n${long.slice(0, APP_CONTEXT_MAX_CHARS - 1)}…\n</codevisor-app-context>\n\nShow me cheaper ones`
    )
    expect(prompt.delivered.map(({ viewId }) => viewId)).toEqual(["view-0", "view-1", "view-2"])
    expect(await run(services.db.listPluginAppContexts(sessionId))).toEqual([])
  })
})
