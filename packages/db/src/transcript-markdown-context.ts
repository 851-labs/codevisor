import { setImmediate as yieldToIO } from "node:timers/promises"

import type Database from "better-sqlite3"

interface Context {
  fence: string
  info: string
  line: string
  overflow: boolean
}
interface Index {
  checkpoints: Map<number, Context>
  pending: Promise<void>
}
const indexes = new WeakMap<Database.Database, Map<string, Index>>()
const empty = (): Context => ({ fence: "", info: "", line: "", overflow: false })

/** Preserve fenced-code rendering when a visible text window starts inside a
 * large code block. The index is disposable, small, and built from bounded SQL
 * batches, yielding between batches; opening navigation never builds it. */
export const transcriptMarkdownContext = async (
  db: Database.Database,
  itemId: string,
  key: string,
  generation: number,
  position: number
): Promise<{ prefix: string; leadingText: string }> => {
  if (position === 0) return { prefix: "", leadingText: "" }
  let cache = indexes.get(db)
  if (!cache) {
    cache = new Map()
    indexes.set(db, cache)
  }
  const identity = JSON.stringify([itemId, key, generation])
  let index = cache.get(identity)
  if (!index) index = { checkpoints: new Map([[0, empty()]]), pending: Promise.resolve() }
  cache.delete(identity)
  cache.set(identity, index)
  if (cache.size > 8) cache.delete(cache.keys().next().value!)
  const owned = index
  const work = owned.pending.then(async () => {
    let start = 0
    for (const point of owned.checkpoints.keys())
      if (point <= position && point > start) start = point
    const context = { ...owned.checkpoints.get(start)! }
    const query = db.prepare(`select position, text from transcript_text_chunks
      where item_id = ? and entry_key = ? and position >= ? and position < ? order by position limit 128`)
    while (start < position) {
      const rows = query.all(itemId, key, start, position) as Array<{
        position: number
        text: string
      }>
      if (rows.length === 0) break
      for (const row of rows) {
        consume(context, row.text)
        start = row.position + 1
      }
      checkpoint(owned, start, context)
      if (start < position) await yieldToIO()
    }
    return {
      prefix: context.fence ? `${context.fence}${context.info}\n` : "",
      leadingText: context.overflow ? "" : context.line
    }
  })
  owned.pending = work.then(
    () => {},
    () => {}
  )
  return work
}

const checkpoint = (index: Index, position: number, context: Context): void => {
  index.checkpoints.set(position, { ...context })
  // The origin is always retained so backwards scrolling can rebuild an old
  // range. Text and parse trees are never retained by this index.
  while (index.checkpoints.size > 33) {
    const candidate = [...index.checkpoints.keys()].find((key) => key !== 0 && key !== position)
    index.checkpoints.delete(candidate!)
  }
}

const consume = (state: Context, source: string): void => {
  let start = 0
  while (start < source.length) {
    const newline = source.indexOf("\n", start)
    const end = newline < 0 ? source.length : newline
    if (!state.overflow) {
      if (state.line.length + end - start > 1024) state.overflow = true
      else state.line += source.slice(start, end)
    }
    if (newline < 0) return
    if (!state.overflow) consumeLine(state, state.line.replace(/\r$/, ""))
    state.line = ""
    state.overflow = false
    start = newline + 1
  }
}

const consumeLine = (state: Context, line: string): void => {
  const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
  if (!marker) return
  const fence = marker[1]!
  const rest = marker[2]!
  if (state.fence) {
    if (fence[0] === state.fence[0] && fence.length >= state.fence.length && rest.trim() === "") {
      state.fence = ""
      state.info = ""
    }
  } else if (fence[0] !== "`" || !rest.includes("`")) {
    state.fence = fence.slice(0, 1024)
    state.info = rest.trim().slice(0, 256)
  }
}
