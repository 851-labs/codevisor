import type { AttachmentRef, FileMetadata } from "@herdman/api"
import { useCallback, useEffect, useRef, useState } from "react"

import { useApi } from "../../lib/api"

export const MAX_COMPOSER_ATTACHMENTS = 10
export const MAX_COMPOSER_ATTACHMENT_BYTES = 25 * 1024 * 1024

export interface ComposerAttachmentItem {
  id: string
  name: string
  mimeType: string
  kind: "image" | "file"
  sizeBytes: number
  previewUrl?: string
  state: "uploading" | "uploaded" | "failed"
  error?: string
}

interface StoredAttachment extends ComposerAttachmentItem {
  file: File
  uploaded?: AttachmentRef
}

function attachmentRef(metadata: FileMetadata): AttachmentRef {
  return {
    fileId: metadata.id,
    name: metadata.name,
    mimeType: metadata.mimeType,
    sizeBytes: metadata.sizeBytes,
    kind: metadata.kind
  }
}

function messageFrom(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function hasLocalPreview(file: File): boolean {
  return (
    file.type.startsWith("image/") ||
    file.type === "application/pdf" ||
    file.name.toLowerCase().endsWith(".pdf")
  )
}

export function useComposerAttachments() {
  const { client } = useApi()
  const [attachments, setAttachmentState] = useState<StoredAttachment[]>([])
  const [error, setError] = useState<string>()
  const attachmentsRef = useRef<StoredAttachment[]>([])
  const uploadTasks = useRef(new Map<string, Promise<void>>())

  const setAttachments = useCallback(
    (update: (current: StoredAttachment[]) => StoredAttachment[]) => {
      setAttachmentState((current) => {
        const next = update(current)
        attachmentsRef.current = next
        return next
      })
    },
    []
  )

  const startUpload = useCallback(
    (attachment: StoredAttachment) => {
      const task = client
        .uploadFile(attachment.file)
        .then((metadata) => {
          const uploaded = attachmentRef(metadata)
          setAttachments((current) =>
            current.map((entry) =>
              entry.id === attachment.id
                ? { ...entry, state: "uploaded", error: undefined, uploaded }
                : entry
            )
          )
        })
        .catch((error: unknown) => {
          setAttachments((current) =>
            current.map((entry) =>
              entry.id === attachment.id
                ? { ...entry, state: "failed", error: messageFrom(error) }
                : entry
            )
          )
        })
        .finally(() => {
          uploadTasks.current.delete(attachment.id)
        })
      uploadTasks.current.set(attachment.id, task)
    },
    [client, setAttachments]
  )

  const stageFiles = useCallback(
    (files: readonly File[]) => {
      if (files.length === 0) return
      setError(undefined)
      let acceptedCount = attachmentsRef.current.length
      for (const file of files) {
        if (acceptedCount >= MAX_COMPOSER_ATTACHMENTS) {
          setError(`A message can carry at most ${MAX_COMPOSER_ATTACHMENTS} attachments.`)
          return
        }
        acceptedCount += 1
        const kind = file.type.startsWith("image/") ? "image" : "file"
        const previewUrl = hasLocalPreview(file) ? URL.createObjectURL(file) : undefined
        const attachment: StoredAttachment = {
          id: crypto.randomUUID(),
          file,
          name: file.name,
          mimeType: file.type || "application/octet-stream",
          kind,
          sizeBytes: file.size,
          previewUrl,
          state: file.size > MAX_COMPOSER_ATTACHMENT_BYTES ? "failed" : "uploading",
          error: file.size > MAX_COMPOSER_ATTACHMENT_BYTES ? "Larger than 25 MB" : undefined
        }
        setAttachments((current) => [...current, attachment])
        if (attachment.state === "uploading") startUpload(attachment)
      }
    },
    [setAttachments, startUpload]
  )

  const removeAttachment = useCallback(
    (id: string) => {
      const existing = attachmentsRef.current.find((entry) => entry.id === id)
      if (existing?.previewUrl != null) URL.revokeObjectURL(existing.previewUrl)
      uploadTasks.current.delete(id)
      setAttachments((current) => current.filter((entry) => entry.id !== id))
    },
    [setAttachments]
  )

  const retryAttachment = useCallback(
    (id: string) => {
      const existing = attachmentsRef.current.find((entry) => entry.id === id)
      if (existing == null || existing.file.size > MAX_COMPOSER_ATTACHMENT_BYTES) return
      setAttachments((current) =>
        current.map((entry) =>
          entry.id === id ? { ...entry, state: "uploading", error: undefined } : entry
        )
      )
      startUpload(existing)
    },
    [setAttachments, startUpload]
  )

  const clearAttachments = useCallback(() => {
    for (const attachment of attachmentsRef.current) {
      if (attachment.previewUrl != null) URL.revokeObjectURL(attachment.previewUrl)
    }
    uploadTasks.current.clear()
    setError(undefined)
    setAttachments(() => [])
  }, [setAttachments])

  const collectForSend = useCallback(async (): Promise<AttachmentRef[]> => {
    await Promise.all([...uploadTasks.current.values()])
    const failed = attachmentsRef.current.find((entry) => entry.state === "failed")
    if (failed != null) {
      throw new Error("An attachment failed to upload. Retry or remove it, then send again.")
    }
    const pending = attachmentsRef.current.find((entry) => entry.state === "uploading")
    if (pending != null) {
      throw new Error("An attachment is still uploading.")
    }
    return attachmentsRef.current.flatMap((entry) =>
      entry.uploaded == null ? [] : [entry.uploaded]
    )
  }, [])

  useEffect(() => {
    return () => {
      for (const attachment of attachmentsRef.current) {
        if (attachment.previewUrl != null) URL.revokeObjectURL(attachment.previewUrl)
      }
    }
  }, [])

  return {
    attachments,
    error,
    stageFiles,
    removeAttachment,
    retryAttachment,
    clearAttachments,
    collectForSend
  }
}
