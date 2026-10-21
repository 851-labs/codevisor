import { describe, expect, it } from "vitest"

import { withCompletedDiffs } from "./file-diffs.js"

const files: Record<string, string> = {
  "/work/a.txt": "one\nTWO\nthree\n",
  "/work/new.txt": "fresh\n"
}
const read = async (path: string) => {
  const text = files[path]
  if (text === undefined) throw new Error("missing")
  return text
}

describe("OpenCode file diffs", () => {
  it("rebuilds before and after text for added, modified and deleted files", async () => {
    const update = await withCompletedDiffs(
      { toolCallId: "call_1", content: [{ type: "content" }] },
      {
        files: [
          { file: "new.txt", status: "added", patch: "" },
          {
            file: "a.txt",
            status: "modified",
            patch: "--- a.txt\n+++ a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"
          },
          {
            file: "/work/gone.txt",
            status: "deleted",
            patch: "--- gone.txt\n+++ gone.txt\n@@ -1,1 +0,0 @@\n-bye\n"
          },
          {
            file: "a.txt",
            status: "modified",
            patch: "--- a.txt\n+++ a.txt\n@@ -1,1 +1,1 @@\n-zzz\n+yyy\n"
          },
          { file: "missing.txt", status: "modified", patch: "x" },
          { file: "empty.txt", status: "deleted", patch: "" },
          { nope: true }
        ]
      },
      "/work",
      read
    )
    expect(update.content).toEqual([
      { type: "content" },
      { type: "diff", path: "/work/new.txt", oldText: null, newText: "fresh\n" },
      {
        type: "diff",
        path: "/work/a.txt",
        oldText: "one\ntwo\nthree\n",
        newText: "one\nTWO\nthree\n"
      },
      { type: "diff", path: "/work/gone.txt", oldText: "bye\n", newText: "" }
    ])
  })

  it("leaves updates without recoverable diffs untouched", async () => {
    const update = { toolCallId: "call_1" }
    expect(await withCompletedDiffs(update, undefined, "/work", read)).toBe(update)
    expect(
      await withCompletedDiffs(
        update,
        { files: [{ file: "x", status: "modified", patch: "" }] },
        "/work",
        read
      )
    ).toBe(update)
  })
})
