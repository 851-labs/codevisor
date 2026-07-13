import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import { useCallback, useEffect, useRef, useSyncExternalStore } from "react"

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

export interface StoredComposerAttachment extends ComposerAttachmentItem {
  file: File
  uploaded?: AttachmentRef
}

export interface ComposerAttachmentStoreSnapshot {
  attachments: StoredComposerAttachment[]
  error?: string
}

export interface ComposerAttachmentStore {
  key?: string
  snapshot: ComposerAttachmentStoreSnapshot
  uploadTasks: Map<string, Promise<void>>
  listeners: Set<() => void>
  mountCount: number
}

function createComposerAttachmentStore(key?: string): ComposerAttachmentStore {
  return {
    key,
    snapshot: { attachments: [] },
    uploadTasks: new Map(),
    listeners: new Set(),
    mountCount: 0
  }
}

function disposeComposerAttachmentStore(store: ComposerAttachmentStore) {
  for (const attachment of store.snapshot.attachments) {
    if (attachment.previewUrl != null) URL.revokeObjectURL(attachment.previewUrl)
  }
  store.uploadTasks.clear()
  store.listeners.clear()
  store.snapshot = { attachments: [] }
}

export class ComposerAttachmentStoreCache {
  private readonly stores = new Map<string, ComposerAttachmentStore>()

  constructor(
    private readonly maxIdleStores: number,
    private readonly onEvict: (store: ComposerAttachmentStore) => void
  ) {}

  get(key: string): ComposerAttachmentStore {
    const existing = this.stores.get(key)
    if (existing != null) {
      this.stores.delete(key)
      this.stores.set(key, existing)
      return existing
    }
    const store = createComposerAttachmentStore(key)
    this.stores.set(key, store)
    return store
  }

  has(key: string): boolean {
    return this.stores.has(key)
  }

  retain(store: ComposerAttachmentStore) {
    store.mountCount += 1
    this.trim()
  }

  release(store: ComposerAttachmentStore) {
    store.mountCount = Math.max(0, store.mountCount - 1)
    this.trim()
  }

  trim() {
    while (this.stores.size > this.maxIdleStores) {
      const evictable = [...this.stores.entries()].find(
        ([, store]) => store.mountCount === 0 && store.uploadTasks.size === 0
      )
      if (evictable == null) return
      const [key, store] = evictable
      this.stores.delete(key)
      this.onEvict(store)
    }
  }
}

const composerAttachmentStores = new ComposerAttachmentStoreCache(
  16,
  disposeComposerAttachmentStore
)

function updateStore(
  store: ComposerAttachmentStore,
  update: (current: ComposerAttachmentStoreSnapshot) => ComposerAttachmentStoreSnapshot
) {
  const next = update(store.snapshot)
  if (next === store.snapshot) return
  store.snapshot = next
  for (const listener of store.listeners) listener()
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

export function useComposerAttachments(persistenceKey?: string) {
  const { client } = useApi()
  const localStoreRef = useRef<ComposerAttachmentStore | undefined>(undefined)
  if (localStoreRef.current == null) localStoreRef.current = createComposerAttachmentStore()
  const store =
    persistenceKey == null ? localStoreRef.current : composerAttachmentStores.get(persistenceKey)
  const subscribe = useCallback(
    (listener: () => void) => {
      store.listeners.add(listener)
      return () => store.listeners.delete(listener)
    },
    [store]
  )
  const getSnapshot = useCallback(() => store.snapshot, [store])
  const snapshot = useSyncExternalStore(subscribe, getSnapshot, getSnapshot)

  const setAttachments = useCallback(
    (update: (current: StoredComposerAttachment[]) => StoredComposerAttachment[]) => {
      updateStore(store, (current) => ({ ...current, attachments: update(current.attachments) }))
    },
    [store]
  )

  const setError = useCallback(
    (error: string | undefined) => {
      updateStore(store, (current) => (current.error === error ? current : { ...current, error }))
    },
    [store]
  )

  const startUpload = useCallback(
    (attachment: StoredComposerAttachment) => {
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
          store.uploadTasks.delete(attachment.id)
          composerAttachmentStores.trim()
        })
      store.uploadTasks.set(attachment.id, task)
    },
    [client, setAttachments, store]
  )

  const stageFiles = useCallback(
    (files: readonly File[]) => {
      if (files.length === 0) return
      setError(undefined)
      let acceptedCount = store.snapshot.attachments.length
      for (const file of files) {
        if (acceptedCount >= MAX_COMPOSER_ATTACHMENTS) {
          setError(`A message can carry at most ${MAX_COMPOSER_ATTACHMENTS} attachments.`)
          return
        }
        acceptedCount += 1
        const kind = file.type.startsWith("image/") ? "image" : "file"
        const previewUrl = hasLocalPreview(file) ? URL.createObjectURL(file) : undefined
        const attachment: StoredComposerAttachment = {
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
    [setAttachments, setError, startUpload, store]
  )

  const removeAttachment = useCallback(
    (id: string) => {
      const existing = store.snapshot.attachments.find((entry) => entry.id === id)
      if (existing?.previewUrl != null) URL.revokeObjectURL(existing.previewUrl)
      store.uploadTasks.delete(id)
      setAttachments((current) => current.filter((entry) => entry.id !== id))
    },
    [setAttachments, store]
  )

  const retryAttachment = useCallback(
    (id: string) => {
      const existing = store.snapshot.attachments.find((entry) => entry.id === id)
      if (existing == null || existing.file.size > MAX_COMPOSER_ATTACHMENT_BYTES) return
      setAttachments((current) =>
        current.map((entry) =>
          entry.id === id ? { ...entry, state: "uploading", error: undefined } : entry
        )
      )
      startUpload(existing)
    },
    [setAttachments, startUpload, store]
  )

  const clearAttachments = useCallback(() => {
    for (const attachment of store.snapshot.attachments) {
      if (attachment.previewUrl != null) URL.revokeObjectURL(attachment.previewUrl)
    }
    store.uploadTasks.clear()
    updateStore(store, () => ({ attachments: [] }))
  }, [store])

  const collectForSend = useCallback(async (): Promise<AttachmentRef[]> => {
    await Promise.all(store.uploadTasks.values())
    const failed = store.snapshot.attachments.find((entry) => entry.state === "failed")
    if (failed != null) {
      throw new Error("An attachment failed to upload. Retry or remove it, then send again.")
    }
    const pending = store.snapshot.attachments.find((entry) => entry.state === "uploading")
    if (pending != null) {
      throw new Error("An attachment is still uploading.")
    }
    return store.snapshot.attachments.flatMap((entry) =>
      entry.uploaded == null ? [] : [entry.uploaded]
    )
  }, [store])

  useEffect(() => {
    if (persistenceKey != null) {
      composerAttachmentStores.retain(store)
      return () => composerAttachmentStores.release(store)
    }
    return () => {
      disposeComposerAttachmentStore(store)
    }
  }, [persistenceKey, store])

  return {
    attachments: snapshot.attachments,
    error: snapshot.error,
    stageFiles,
    removeAttachment,
    retryAttachment,
    clearAttachments,
    collectForSend
  }
}
