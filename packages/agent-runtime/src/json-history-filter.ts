/** Removes only the unused Codex thread history arrays while they stream.
 * Neither a giant JSON line nor the array is ever assembled in memory.
 * Transcript content remains in the provider rollout and our transcript store.
 */
export class JsonHistoryFilter {
  private stack: Array<{ path: string[]; object: boolean; key: string; expectsKey: boolean }> = []
  private inString = false
  private escaped = false
  private keyString = false
  private key = ""
  private skipDepth = 0

  push(chunk: string): string {
    const parts: string[] = []
    let start = this.skipDepth > 0 ? -1 : 0
    for (let index = 0; index < chunk.length; index++) {
      const char = chunk[index]!
      if (this.inString) {
        if (this.keyString && this.key.length < 512) this.key += char
        if (this.escaped) this.escaped = false
        else if (char === "\\") this.escaped = true
        else if (char === '"') {
          this.inString = false
          if (this.keyString) {
            const current = this.stack.at(-1)!
            try {
              current.key = JSON.parse(this.key) as string
            } catch {
              current.key = ""
            }
            this.keyString = false
          }
        }
        continue
      }
      if (char === '"') {
        this.inString = true
        this.keyString = this.skipDepth === 0 && this.stack.at(-1)?.expectsKey === true
        if (this.keyString) this.key = '"'
        continue
      }
      if (this.skipDepth > 0) {
        if (char === "[" || char === "{") this.skipDepth += 1
        else if (char === "]" || char === "}") {
          this.skipDepth -= 1
          if (this.skipDepth === 0) start = index + 1
        }
        continue
      }
      const parent = this.stack.at(-1)
      if (char === "{" || char === "[") {
        const path = parent === undefined ? [] : [...parent.path, parent.object ? parent.key : "*"]
        if (
          char === "[" &&
          path.length === 3 &&
          (path[0] === "result" || path[0] === "params") &&
          path[1] === "thread" &&
          path[2] === "turns"
        ) {
          parts.push(chunk.slice(start, index), "[]")
          start = -1
          this.skipDepth = 1
        } else {
          this.stack.push({ path, object: char === "{", key: "", expectsKey: char === "{" })
        }
      } else if (char === "}" || char === "]") {
        this.stack.pop()
      } else if (char === ":" && parent !== undefined) {
        parent.expectsKey = false
      } else if (char === "," && parent !== undefined) {
        parent.expectsKey = parent.object
      }
    }
    if (start >= 0) parts.push(chunk.slice(start))
    return parts.join("")
  }
}
