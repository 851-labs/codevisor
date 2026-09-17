import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { transcriptMarkdownContext } from "./transcript-markdown-context.js"

describe("inline transcript code continuation", () => {
  it("keeps opening and closing fences across arbitrary storage boundaries and backwards reads", async () => {
    const db = new Database(":memory:")
    try {
      db.exec(
        "create table transcript_text_chunks (item_id text, entry_key text, position integer, text text)"
      )
      const blocks = [
        "Before\n``",
        "`swift\nlet value = 1\n",
        "let other = 2\n```\n",
        "After\n~~~json\n",
        '{"ok":true}\n~~~\n',
        "Done"
      ]
      const insert = db.prepare("insert into transcript_text_chunks values ('item', 'key', ?, ?)")
      blocks.forEach((text, index) => insert.run(index, text))
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 1)).leadingText).toBe("``")
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 2)).prefix).toBe("```swift\n")
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 4)).prefix).toBe("~~~json\n")
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 5)).prefix).toBe("")
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 2)).prefix).toBe("```swift\n")
      db.prepare(
        "update transcript_text_chunks set text = 'Ordinary text\n' where position <= 1"
      ).run()
      expect((await transcriptMarkdownContext(db, "item", "key", 2, 2)).prefix).toBe("")
    } finally {
      db.close()
    }
  })

  it("indexes long lines with bounded scan batches without mistaking embedded ticks for fences", async () => {
    const db = new Database(":memory:")
    try {
      db.exec(
        "create table transcript_text_chunks (item_id text, entry_key text, position integer, text text)"
      )
      const insert = db.prepare("insert into transcript_text_chunks values ('item', 'key', ?, ?)")
      for (let position = 0; position < 300; position++) insert.run(position, "x".repeat(8192))
      insert.run(300, "```\n```python\n")
      expect((await transcriptMarkdownContext(db, "item", "key", 1, 301)).prefix).toBe(
        "```python\n"
      )
    } finally {
      db.close()
    }
  })
})

it("bounds cached checkpoints, handles malformed fences, and recovers after read errors", async () => {
  const db = new Database(":memory:")
  try {
    expect(await transcriptMarkdownContext(db, "item", "key", 0, 0)).toEqual({
      prefix: "",
      leadingText: ""
    })
    await expect(transcriptMarkdownContext(db, "item", "key", 0, 1)).rejects.toThrow()
    db.exec(
      "create table transcript_text_chunks (item_id text, entry_key text, position integer, text text)"
    )
    expect(await transcriptMarkdownContext(db, "item", "key", 0, 1)).toEqual({
      prefix: "",
      leadingText: ""
    })
    const insert = db.prepare("insert into transcript_text_chunks values ('item', 'key', ?, ?)")
    const blocks = [
      "```bad`info\n",
      "~~~~long\n",
      "~~~\n",
      "~~~~ trailing\n",
      "```\n",
      "~~~~\r\n",
      "x".repeat(1025)
    ]
    blocks.forEach((text, index) => insert.run(index, text))
    expect((await transcriptMarkdownContext(db, "item", "key", 1, 1)).prefix).toBe("")
    expect((await transcriptMarkdownContext(db, "item", "key", 1, 5)).prefix).toBe("~~~~long\n")
    expect(await transcriptMarkdownContext(db, "item", "key", 1, 7)).toEqual({
      prefix: "",
      leadingText: ""
    })
    for (let index = 7; index < 42; index++) insert.run(index, "\n")
    for (let position = 8; position <= 42; position++)
      expect((await transcriptMarkdownContext(db, "item", "key", 1, position)).prefix).toBe("")
    for (let generation = 2; generation < 12; generation++)
      expect((await transcriptMarkdownContext(db, "item", "key", generation, 1)).prefix).toBe("")
    expect((await transcriptMarkdownContext(db, "item", "key", 1, 2)).prefix).toBe("~~~~long\n")
  } finally {
    db.close()
  }
})
