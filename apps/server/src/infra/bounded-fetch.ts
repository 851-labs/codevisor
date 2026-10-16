export interface BoundedResponse {
  readonly data: Uint8Array
  readonly url: string
}

export type BoundedFetch = (
  url: string,
  limit: number,
  accept: string
) => Promise<BoundedResponse | undefined>

export const makeBoundedFetch =
  (fetchImpl: typeof fetch, timeoutMs: number): BoundedFetch =>
  async (url, limit, accept) => {
    try {
      const response = await fetchImpl(url, {
        credentials: "omit",
        headers: { accept },
        redirect: "follow",
        signal: AbortSignal.timeout(timeoutMs)
      })
      const finalUrl = response.url === "" ? url : response.url
      if (!response.ok || !/^https?:/i.test(finalUrl)) {
        await response.body?.cancel()
        return undefined
      }
      const reader = response.body?.getReader()
      if (reader === undefined) return undefined
      const chunks: Array<Uint8Array> = []
      let size = 0
      const page = !accept.startsWith("image")
      const decoder = new TextDecoder()
      let tail = ""
      while (size < limit) {
        const { done, value } = await reader.read()
        if (done) break
        chunks.push(value)
        size += value.byteLength
        if (!page) continue
        tail = (tail + decoder.decode(value, { stream: true })).slice(-4096)
        if (/<\/head\s*>|<body[\s>]/i.test(tail)) break
      }
      await reader.cancel()
      if (!page && size >= limit) return undefined
      return { data: new Uint8Array(Buffer.concat(chunks)), url: finalUrl }
    } catch {
      return undefined
    }
  }
