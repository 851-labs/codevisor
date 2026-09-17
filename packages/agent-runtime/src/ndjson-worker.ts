import { parentPort } from "node:worker_threads"

import { JsonHistoryFilter } from "./json-history-filter.js"

const port = parentPort!
const filter = new JsonHistoryFilter()
let fragments: string[] = []
port.on("message", ({ chunk }: { chunk: string }) => {
  const filtered = filter.push(chunk)
  let start = 0
  while (start < filtered.length) {
    const newline = filtered.indexOf("\n", start)
    if (newline < 0) break
    fragments.push(filtered.slice(start, newline))
    const line = fragments.join("")
    fragments = []
    start = newline + 1
    try {
      port.postMessage({ message: JSON.parse(line) as unknown })
    } catch {
      // Codex can print non-protocol startup diagnostics on stdout.
    }
  }
  if (start < filtered.length) fragments.push(filtered.slice(start))
  port.postMessage({ consumed: chunk.length })
})
