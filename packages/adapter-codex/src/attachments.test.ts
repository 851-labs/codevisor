import { describe, expect, it } from "vitest"
import { run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("maps attachments: images as localImage paths, files as path notes", async () => {
    const { client, created } = await setup()
    const promptPromise = run(
      created!.handle.prompt({
        text: "check these",
        attachments: [
          {
            data: Buffer.from("png"),
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/att/shot.png"
          },
          {
            data: Buffer.from("csv"),
            kind: "file",
            mimeType: "text/csv",
            name: "data.csv",
            path: "/tmp/att/data.csv"
          }
        ]
      })
    )
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-att", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      input: [
        {
          text: "check these\n\n[Attached file: /tmp/att/data.csv (data.csv, text/csv)]",
          type: "text"
        },
        { path: "/tmp/att/shot.png", type: "localImage" }
      ]
    })
  })

  it("sends an image-only prompt without a text item", async () => {
    const { client, created } = await setup()
    const promptPromise = run(
      created!.handle.prompt({
        text: "",
        attachments: [
          {
            data: Buffer.from("png"),
            kind: "image",
            mimeType: "image/png",
            name: "only.png",
            path: "/tmp/att/only.png"
          }
        ]
      })
    )
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-img", status: "completed" }
    })
    await promptPromise
    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      input: [{ path: "/tmp/att/only.png", type: "localImage" }]
    })
  })
})
