export {
  AttachmentStoreError,
  makeAttachmentStore,
  migrateAttachmentBlobs,
  type AttachmentStore,
  type StoredAttachmentObject
} from "./attachment-store.js"

export * from "./errors.js"

export * from "./identity.js"
export * from "./ids.js"

export {
  botPath,
  botsRoot,
  isBotFolder,
  isManagedFolder,
  isScratchFolder,
  legacyBotsRoot,
  legacyWorktreeTrashRoot,
  managedRepoPath,
  scratchWorkspacePath,
  scratchWorkspacesRoot,
  worktreeNameAt,
  worktreePath,
  worktreePathBeside,
  worktreesRoot,
  worktreeTrashRoot
} from "./paths.js"

export * from "./rows.js"

export * from "./service.js"

export type { AutoResumeRecord, AutoResumeState } from "./auto-resume-service.js"

export type {
  WorkspaceFileEdit,
  WorkspaceMediaCursor,
  WorkspaceMediaRow,
  WorkspaceMessageText
} from "./workspace-media.js"
export type {
  CreateWorkspaceWithSessionRecord,
  UpsertWorkspaceRecord
} from "./workspace-service-types.js"
