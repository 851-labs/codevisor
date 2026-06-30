import { describe, expect, it } from "vitest"
import {
  EventEnvelope,
  TerminalClientFrame,
  Workspace,
  decode,
  encode,
  endpoints,
  isoTimestamp,
  makeOpenApiDocument
} from "./index.js"

describe("@herdman/api", () => {
  it("decodes and encodes workspace payloads", () => {
    const workspace = decode(Workspace)({
      id: "workspace-1",
      name: "HerdMan",
      folderPath: "/Users/me/src/HerdMan",
      isArchived: false,
      symbolName: "folder",
      origin: "herdman",
      createdAt: "2026-06-30T00:00:00.000Z"
    })

    expect(encode(Workspace)(workspace)).toEqual({
      id: "workspace-1",
      name: "HerdMan",
      folderPath: "/Users/me/src/HerdMan",
      isArchived: false,
      symbolName: "folder",
      origin: "herdman",
      createdAt: "2026-06-30T00:00:00.000Z"
    })
  })

  it("rejects invalid terminal frames", () => {
    expect(() => decode(TerminalClientFrame)({ type: "resize", cols: "80", rows: 24 })).toThrow()
  })

  it("allows opaque event payloads", () => {
    const event = decode(EventEnvelope)({
      id: 1,
      serverId: "local",
      kind: "session.output",
      subjectId: "session-1",
      createdAt: "2026-06-30T00:00:00.000Z",
      payload: { text: "hello" }
    })
    expect(event.payload).toEqual({ text: "hello" })
  })

  it("exports the server endpoint inventory as OpenAPI metadata", () => {
    const doc = makeOpenApiDocument("0.1.0")
    expect(doc.info.version).toBe("0.1.0")
    expect(Object.keys(doc.paths).sort()).toEqual([...endpoints].sort())
  })

  it("creates ISO timestamps for server state", () => {
    expect(Date.parse(isoTimestamp())).not.toBeNaN()
  })
})
