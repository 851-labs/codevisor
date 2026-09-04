import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { createHash } from "node:crypto"
import { run, type CodevisorServerServices } from "../server-context.js"
import { attachmentRef, captureAssistantFile } from "./assistant-files.js"

// Image bytes are an internal adapter payload. Persist them before publishing
// the tool update so neither the event log nor connected devices carry base64.
export const persistGeneratedImage = async (
  services: CodevisorServerServices,
  event: RuntimeEvent
): Promise<RuntimeEvent> => {
  const payload = event.payload as Record<string, unknown>
  if (
    event.kind !== "session.output" ||
    payload?.kind !== "image_generation" ||
    payload.sessionUpdate !== "tool_call_update"
  )
    return event
  const { generatedImage, ...published } = payload
  if (payload.status !== "completed") return { ...event, payload: published }
  const input = generatedImage as { result?: string; savedPath?: string } | undefined
  try {
    const fileId =
      "generated-" +
      createHash("sha256")
        .update(JSON.stringify([event.subjectId, payload.parentToolCallId, payload.toolCallId]))
        .digest("hex")
    const existing = await run(services.db.getFileMetadata(fileId))
    const attachment =
      existing === undefined
        ? await captureAssistantFile(
            services,
            input?.result
              ? {
                  data: Buffer.from(input.result, "base64"),
                  name: "Generated image.png",
                  mimeType: "image/png"
                }
              : input?.savedPath
                ? { path: input.savedPath }
                : (() => {
                    throw new Error("Image generation returned no image")
                  })(),
            [],
            fileId
          )
        : attachmentRef(existing)
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
