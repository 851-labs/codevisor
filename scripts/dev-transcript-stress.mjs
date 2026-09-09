#!/usr/bin/env node

// Run the native dev runner with TRANSCRIPT_STRESS=1 first. The endpoint
// acknowledges durable events; issuing the next command never requires a
// guessed delay. Only seed creates chats; chunk/finish require a fixture ID.
const [action, value, ...words] = process.argv.slice(2)
const baseURL = process.env.TRANSCRIPT_STRESS_URL
if (!baseURL)
  throw new Error(
    "Set TRANSCRIPT_STRESS_URL to this worktree's local server URL from the dev runner"
  )
const presets = {
  paragraph: "A long paragraph **with styling**, emoji 👩🏽‍💻, 日本語 and `code`. ".repeat(4000),
  code:
    "```swift\n" +
    Array.from({ length: 5000 }, (_, i) => `let value${i} = "Line ${i}"`).join("\n") +
    "\n```",
  table:
    "| Item | Value | Details |\n| --- | ---: | --- |\n" +
    Array.from(
      { length: 2000 },
      (_, i) => `| ${i} | **${i * 7}** | Text with wrapping and inline \`code\` |`
    ).join("\n")
}
let body
if (action === "seed") {
  const preset = value ?? "mixed"
  if (preset !== "mixed" && !(preset in presets))
    throw new Error("Preset: mixed, paragraph, code, table")
  body = {
    action,
    title: `Stress ${preset}`,
    folderPath: process.cwd(),
    turns: preset === "mixed" ? 500 : 1,
    ...(presets[preset] ? { text: presets[preset] } : {})
  }
} else if (action === "chunk" || action === "finish") {
  if (!value) throw new Error("Provide the sessionId returned by seed")
  body = { action, sessionId: value }
  if (action === "chunk") {
    body.text = words.join(" ")
    if (words[0] === "--stdin") {
      body.text = ""
      process.stdin.setEncoding("utf8")
      for await (const chunk of process.stdin) body.text += chunk
    }
  }
} else {
  throw new Error(
    "Usage: node scripts/dev-transcript-stress.mjs seed [preset] | chunk <sessionId> <text|--stdin> | finish <sessionId>"
  )
}
const response = await fetch(new URL("/dev/transcript-stress", baseURL), {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body)
})
const result = await response.text()
if (!response.ok) throw new Error(`${response.status}: ${result}`)
process.stdout.write(`${result}\n`)
