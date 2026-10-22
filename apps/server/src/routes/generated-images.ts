import { createHash } from "node:crypto"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { AttachmentRef } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"
import { field, isRecord } from "../unknown-values.js"
import { attachmentRef, captureAssistantFile } from "./assistant-files.js"

const generatedImageSource = (result: unknown, savedPath: unknown) => {
  if (typeof result === "string" && result !== "") {
    return {
      data: Buffer.from(result, "base64"),
      name: "Generated image.png",
      mimeType: "image/png"
    }
  }
  if (typeof savedPath === "string" && savedPath !== "") return { path: savedPath }
  throw new Error("Image generation returned no image")
}

export const persistGeneratedImage = async (
  services: CodevisorServerServices,
  event: RuntimeEvent
): Promise<RuntimeEvent> => {
  const payload = event.payload
  if (
    event.kind !== "session.output" ||
    !isRecord(payload) ||
    payload.kind !== "image_generation" ||
    payload.sessionUpdate !== "tool_call_update"
  )
    return event
  const { generatedImage, ...published } = payload
  if (payload.status !== "completed") return { ...event, payload: published }
  const result = field(generatedImage, "result")
  const savedPath = field(generatedImage, "savedPath")
  try {
    const fileId =
      "generated-" +
      createHash("sha256")
        .update(JSON.stringify([event.subjectId, payload.parentToolCallId, payload.toolCallId]))
        .digest("hex")
    const existing = await run(services.db.getFileMetadata(fileId))
    let attachment: AttachmentRef
    if (existing === undefined) {
      attachment = await captureAssistantFile(
        services,
        generatedImageSource(result, savedPath),
        [],
        fileId
      )
    } else {
      attachment = attachmentRef(existing)
    }
    return { ...event, payload: { ...published, rawOutput: { attachment } } }
  } catch (cause) {
    console.error(
      `Could not preserve generated image: ${cause instanceof Error ? cause.message : String(cause)}`
    )
    return {
      ...event,
      payload: {
        ...published,
        status: "failed",
        title: "Could not save generated image",
        rawOutput: { message: "The generated image could not be saved. Try generating it again." }
      }
    }
  }
}
