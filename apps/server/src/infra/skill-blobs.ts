import type { BlobStore } from "@codevisor/sync"

export interface BlobOwner {
  readonly blobs: BlobStore
}

export const blobUnverified = (deps: BlobOwner, hash: string): boolean =>
  !verifiedBlobIds.has(hash) || !deps.blobs.has(hash)

export const markBlobVerified = (hash: string): void => {
  verifiedBlobIds.add(hash)
}

const verifiedBlobIds = new Set<string>()
