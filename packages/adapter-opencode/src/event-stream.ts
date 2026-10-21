export async function* serverSentEvents(
  body: ReadableStream<Uint8Array>
): AsyncGenerator<unknown, void, undefined> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ""
  let data: Array<string> = []
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) return
      buffer += decoder.decode(value, { stream: true })
      for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
        const line = buffer.slice(0, newline).replace(/\r$/, "")
        buffer = buffer.slice(newline + 1)
        if (line.startsWith("data:")) {
          data.push(line.slice(line.startsWith("data: ") ? 6 : 5))
          continue
        }
        if (line !== "" || data.length === 0) continue
        const text = data.join("\n")
        data = []
        let event: unknown
        try {
          event = JSON.parse(text)
        } catch {
          continue
        }
        yield event
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined)
  }
}
