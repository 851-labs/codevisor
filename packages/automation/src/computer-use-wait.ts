import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

export const computerUseState = (result: CallToolResult): Record<string, unknown> => {
  if (result.isError)
    throw new Error(
      result.content
        .filter((c) => c.type === "text")
        .map((c) => c.text)
        .join("\n")
    )
  const text = result.content.find((c) => c.type === "text")?.text
  if (typeof text !== "string") throw new Error("Computer Use returned no state")
  const value: unknown = JSON.parse(text)
  if (value === null || typeof value !== "object" || Array.isArray(value))
    throw new Error("Computer Use returned an invalid state")
  return value as Record<string, unknown>
}

export const waitForComputerState = async (
  args: Readonly<Record<string, unknown>>,
  observe: (args: Readonly<Record<string, unknown>>) => Promise<CallToolResult>,
  clock = {
    now: () => performance.now(),
    sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))
  }
): Promise<CallToolResult> => {
  if (typeof args.text !== "string" && typeof args.role !== "string")
    throw new Error("wait_for requires text or role")
  if (args.text === "" || args.role === "") throw new Error("Wait conditions cannot be empty")
  const timeout = args.timeout_ms ?? 10000
  if (typeof timeout !== "number" || !Number.isInteger(timeout) || timeout < 0 || timeout > 30000)
    throw new Error("timeout_ms must be 0–30000")
  if (args.state !== undefined && args.state !== "present" && args.state !== "absent")
    throw new Error("state must be present or absent")
  const {
    text,
    role,
    state: requested = "present",
    timeout_ms: _timeout,
    screenshot,
    ...options
  } = args
  const deadline = clock.now() + timeout
  const matches = (result: CallToolResult) => {
    const state = computerUseState(result)
    const tree = typeof state.text === "string" ? state.text : ""
    const present =
      role === undefined
        ? tree.includes(String(text))
        : tree
            .split("\n")
            .some(
              (line) =>
                line.trim().split(/\s+/)[1] === String(role).replaceAll(" ", "_") &&
                (text === undefined || line.includes(String(text)))
            )
    return requested === "absent" ? !present : present
  }
  while (true) {
    let result = await observe({ ...options, screenshot: false, disableDiff: true })
    let matched = matches(result)
    if (matched && screenshot === true) {
      result = await observe({ ...options, screenshot: true, disableDiff: true })
      matched = matches(result)
    }
    if (matched || clock.now() >= deadline) {
      const state = computerUseState(result)
      return {
        ...result,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              ...state,
              matched,
              ...(matched ? {} : { waitError: "Timed out waiting for the requested state" })
            })
          },
          ...result.content.filter((c) => c.type !== "text")
        ]
      }
    }
    await clock.sleep(Math.min(200, Math.max(0, deadline - clock.now())))
  }
}
