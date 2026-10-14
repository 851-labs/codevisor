export const rewriteAgentLines = (
  input: ReadableStream<Uint8Array>,
  rewrite: (line: string) => string
): ReadableStream<Uint8Array> => {
  const decoder = new TextDecoder()
  const encoder = new TextEncoder()
  let buffered = ""
  return input.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        buffered += decoder.decode(chunk, { stream: true })
        const lines = buffered.split("\n")
        buffered = lines.pop() ?? ""
        for (const line of lines) controller.enqueue(encoder.encode(`${rewrite(line)}\n`))
      },
      flush(controller) {
        buffered += decoder.decode()
        if (buffered.length > 0) controller.enqueue(encoder.encode(rewrite(buffered)))
      }
    })
  )
}
